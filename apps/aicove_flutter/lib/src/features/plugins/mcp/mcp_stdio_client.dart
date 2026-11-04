import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/api/request_control.dart';
import 'mcp_connector.dart';
import 'mcp_http_client.dart';
import 'mcp_stdio_launch.dart';
import 'mcp_process_cleanup.dart';

/// Newline-delimited JSON-RPC over one shared subprocess. Calls are dispatched
/// once; process death and timeout never replay a potentially side-effecting call.
class McpStdioClient implements McpClientPort {
  McpStdioClient({
    required this.connector,
    this.requestTimeout = const Duration(seconds: 120),
    this.stopTimeout = const Duration(seconds: 2),
  });

  final McpConnector connector;
  final Duration requestTimeout;
  final Duration stopTimeout;
  Process? _process;
  Future<void>? _starting;
  Future<void>? _initializing;
  Future<void>? _stopping;
  bool _closed = false;
  bool _initialized = false;
  int _nextId = 1;
  String _serverName = '';
  String _stderr = '';
  bool _stderrTruncated = false;
  bool _exited = false;
  bool get isClosed => _closed;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  Future<void> get stopped => _stopping ?? Future<void>.value();

  String _redact(String message) {
    var text = message;
    final secrets =
        {
            ...connector.env.values,
            connector.bearerToken,
            ...connector.headers.values,
            ...Platform.environment.entries
                .where(
                  (e) => RegExp(
                    r'token|key|password|secret|auth|cookie',
                    caseSensitive: false,
                  ).hasMatch(e.key),
                )
                .map((e) => e.value),
          }.where((s) => s.isNotEmpty).toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in secrets) {
      text = text.replaceAll(secret, '[已隐藏]');
    }
    return text;
  }

  Future<void> _start() => _starting ??= _startProcess().catchError((
    Object error,
    StackTrace stack,
  ) {
    close();
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _startProcess() async {
    if (_closed) throw const McpException('本地 MCP 连接已关闭');
    if (!McpConnector.supportsStdio) throw const McpException('本地命令仅桌面端可用');
    try {
      final env = mcpProcessEnvironment(overrides: connector.env);
      final rawCwd = expandMcpHome(
        connector.cwd.trim(),
        env['HOME'] ?? env['USERPROFILE'],
      );
      final cwd = rawCwd.isEmpty ? null : Directory(rawCwd).absolute.path;
      final launch = resolveMcpStdioLaunch(
        connector.command,
        connector.args,
        env,
        cwd: cwd,
      );
      final process = await Process.start(
        launch.command,
        launch.args,
        workingDirectory: cwd,
        environment: env,
        runInShell: launch.runInShell,
      );
      _process = process;
      unawaited(
        process.stdin.done.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _fail(const McpException('本地 MCP 输入管道已关闭'));
          },
        ),
      );
      var bufferedChars = 0;
      process.stdout
          .transform(utf8.decoder)
          .map((chunk) {
            final lastNewline = chunk.lastIndexOf('\n');
            bufferedChars = lastNewline < 0
                ? bufferedChars + chunk.length
                : chunk.length - lastNewline - 1;
            if (bufferedChars > 16 * 1024 * 1024) {
              throw const FormatException('MCP 单条响应过大');
            }
            return chunk;
          })
          .transform(const LineSplitter())
          .listen(
            _receive,
            onError: (Object _) => _fail(
              const McpException('本地 MCP stdout 协议错误（需要 UTF-8 JSON 行）'),
            ),
            onDone: () => unawaited(_stdoutDone(process)),
          );
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((
        chunk,
      ) {
        _stderr = '$_stderr$chunk';
        if (_stderr.length > 2000) {
          _stderrTruncated = true;
          _stderr = _stderr.substring(_stderr.length - 2000);
        }
      });
      unawaited(
        process.exitCode.then((code) {
          _exited = true;
          _fail(McpException('本地 MCP 进程已退出（退出码 $code）${_stderrSuffix()}'));
        }),
      );
      if (_closed && !_exited) process.kill();
    } on ProcessException catch (e) {
      if (e.message.startsWith('批处理命令')) throw McpException(e.message);
      throw const McpException('无法启动本地 MCP：找不到程序、目录无效或没有执行权限，请检查启动命令和 PATH');
    } on FileSystemException {
      throw const McpException('无法读取本地 MCP 启动目录或 PATH，请检查权限');
    }
  }

  Future<void> _stdoutDone(Process process) async {
    if (_closed) return;
    try {
      final code = await process.exitCode.timeout(
        const Duration(milliseconds: 100),
      );
      _exited = true;
      _fail(McpException('本地 MCP 进程已退出（退出码 $code）${_stderrSuffix()}'));
    } on TimeoutException {
      _fail(McpException('本地 MCP 输出已关闭${_stderrSuffix()}'));
    }
  }

  String _stderrSuffix() => _stderrTruncated
      ? '（stderr 过长，已隐藏）'
      : _stderr.trim().isEmpty
      ? ''
      : '：${_redact(_stderr.trim())}';

  void _receive(String line) {
    if (_closed || line.trim().isEmpty) return;
    try {
      final value = jsonDecode(line);
      if (value is! Map || value['jsonrpc'] != '2.0') {
        throw const FormatException();
      }
      final message = Map<String, dynamic>.from(value);
      final method = message['method'];
      if (method is String) {
        // This client advertises no sampling/roots/elicitation capabilities.
        if (message.containsKey('id')) {
          _write({
            'jsonrpc': '2.0',
            'id': message['id'],
            'error': {'code': -32601, 'message': 'Client method not supported'},
          });
        }
        return;
      }
      final id = message['id'];
      if (id is! int ||
          (message['result'] is! Map && message['error'] is! Map)) {
        throw const FormatException();
      }
      final pending = _pending.remove(id);
      if (pending == null) return; // Late response to cancellation/timeout.
      final error = message['error'];
      if (error is Map) {
        pending.completeError(
          _McpRpcException(
            _redact('MCP 错误：${error['message'] ?? error['code']}'),
          ),
        );
      } else {
        pending.complete(Map<String, dynamic>.from(message['result'] as Map));
      }
    } catch (_) {
      _fail(
        const McpException('本地 MCP stdout 协议错误：只能输出 JSON-RPC，日志请输出到 stderr'),
      );
    }
  }

  void _write(Map<String, dynamic> message) {
    if (_closed || _process == null) throw const McpException('本地 MCP 连接已关闭');
    _process!.stdin.writeln(jsonEncode(message));
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params, {
    bool cancellable = true,
  }) async {
    if (_closed) throw const McpException('本地 MCP 连接已关闭');
    final signal = cancellable ? RequestControl.cancellation : null;
    signal?.throwIfCancelled();
    final id = _nextId++;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    var sent = false;
    try {
      _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
      sent = true;
      if (signal != null) {
        unawaited(
          signal.whenCancelled.then((_) {
            if (_pending.remove(id) == null) return;
            _cancel(id);
            pending.completeError(
              McpException(
                method == 'tools/call'
                    ? 'MCP 工具调用已取消；请求已发出，执行结果未知，请勿自动重试'
                    : 'MCP 请求已取消',
              ),
            );
          }),
        );
      }
      return await pending.future.timeout(requestTimeout);
    } on TimeoutException {
      _cancel(id);
      throw McpException(
        method == 'tools/call'
            ? 'MCP 工具调用超时；请求已发出，执行结果未知，请勿自动重试'
            : '等待本地 MCP 响应超时（$method）',
      );
    } on McpException catch (e) {
      if (method == 'tools/call' &&
          sent &&
          e is! _McpRpcException &&
          !e.message.contains('结果未知')) {
        throw McpException('${e.message}；请求已发出，执行结果未知，请勿自动重试');
      }
      rethrow;
    } on Object {
      throw McpException(
        sent && method == 'tools/call'
            ? '本地 MCP 连接中断；请求已发出，执行结果未知，请勿自动重试'
            : '无法写入本地 MCP 进程',
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _cancel(int id) {
    if (_closed) return;
    try {
      _write({
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': id, 'reason': 'Request cancelled'},
      });
    } catch (_) {
      /* The connection may already be closing. */
    }
  }

  Future<void> _ensureInitialized() async {
    await _start();
    if (_initialized) return;
    await (_initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    ));
  }

  Future<void> _initialize() async {
    final result = await _send('initialize', {
      'protocolVersion': McpHttpClient.protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': 'AIcove', 'version': '1.0.0'},
    }, cancellable: false);
    final info = result['serverInfo'];
    _serverName = info is Map
        ? (info['title'] ?? info['name'] ?? '').toString()
        : '';
    _write({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    _initialized = true;
  }

  @override
  Future<McpServerSnapshot> listTools() async {
    await _ensureInitialized();
    final tools = <McpToolInfo>[];
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final result = await _send('tools/list', {
        if (cursor != null) 'cursor': cursor,
      });
      if (result['tools'] is! List) throw const McpException('MCP 工具清单格式无效');
      for (final item in result['tools'] as List) {
        if (item is! Map ||
            item['name'] is! String ||
            (item['name'] as String).isEmpty) {
          throw const McpException('MCP 工具清单包含无效工具');
        }
        tools.add(McpToolInfo.fromJson(Map<String, dynamic>.from(item)));
      }
      final next = result['nextCursor'];
      if (next == null || next == '') {
        return McpServerSnapshot(serverName: _serverName, tools: tools);
      }
      if (next is! String || !cursors.add(next)) {
        throw const McpException('MCP 工具清单分页游标无效');
      }
      cursor = next;
    }
    throw const McpException('MCP 工具清单超过 20 页，未保存不完整清单');
  }

  @override
  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    await _ensureInitialized();
    final result = await _send('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    return McpHttpClient.decodeToolResult(name, result);
  }

  void _fail(McpException error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(const McpException('本地 MCP 连接已关闭'));
      }
    }
    _pending.clear();
    _stopping = _stop();
  }

  Future<void> _stop() async {
    try {
      await _starting;
    } catch (_) {}
    final process = _process;
    if (process == null) return;
    // Capture descendants before closing stdin: a wrapper may exit immediately
    // and reparent its worker. Never send a signal to AIcove's process group.
    final descendants = await captureMcpDescendants(process.pid);
    if (Platform.isWindows && descendants == null) {
      // If enumeration fails, stop the tree while its wrapper is still alive;
      // closing stdin first could lose the only usable parent/child link.
      await stopMcpWindowsProcesses(
        const [],
        parentPid: _exited ? null : process.pid,
      );
    }
    try {
      await process.stdin.close().timeout(stopTimeout);
      await process.exitCode.timeout(stopTimeout);
    } catch (_) {
      /* Escalate only this process and its observed descendants. */
    }
    if (Platform.isWindows) {
      if (descendants != null) {
        await stopMcpWindowsProcesses(
          descendants,
          parentPid: _exited ? null : process.pid,
        );
      }
    } else {
      for (final pid in (descendants ?? <int>[]).reversed) {
        Process.killPid(pid, ProcessSignal.sigterm);
      }
      if (!_exited) process.kill(ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final pid in (descendants ?? <int>[]).reversed) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      if (!_exited) process.kill(ProcessSignal.sigkill);
    }
  }
}

class _McpRpcException extends McpException {
  const _McpRpcException(super.message);
}
