import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_connector.dart';

/// MCP 调用失败（网络、HTTP 状态、JSON-RPC 错误或响应格式不对）。
class McpException implements Exception {
  const McpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// initialize＋tools/list 的结果。
class McpServerSnapshot {
  const McpServerSnapshot({required this.serverName, required this.tools});

  final String serverName;
  final List<McpToolInfo> tools;
}

/// tools/call 的结果，已压平成可回给模型的文本。
class McpToolCallResult {
  const McpToolCallResult({required this.text, required this.isError});

  final String text;
  final bool isError;
}

/// 远程 MCP 服务客户端，只实现 Streamable HTTP 传输上的工具能力：
/// initialize、tools/list、tools/call。响应既接受 application/json，
/// 也接受 text/event-stream（读到对应 id 的响应即停止）。
///
/// 会话 id 由服务端在 initialize 时下发；会话过期（带会话 id 时返回 404）
/// 自动重新握手一次。
class McpHttpClient {
  McpHttpClient({
    required this.url,
    this.headers = const <String, String>{},
    http.Client? client,
    this.clientVersion = '1.0.0',
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const protocolVersion = '2025-06-18';
  static const listTimeout = Duration(seconds: 30);
  static const callTimeout = Duration(seconds: 120);

  /// 回给模型的单次工具结果上限，避免一次调用撑爆上下文。
  static const maxResultChars = 20000;

  final String url;
  final Map<String, String> headers;
  final String clientVersion;
  final http.Client _client;
  final bool _ownsClient;

  String? _sessionId;
  String? _negotiatedVersion;
  String _serverName = '';
  Future<void>? _initializing;
  int _nextId = 1;

  Future<McpServerSnapshot> listTools() async {
    await _ensureInitialized();
    final tools = <McpToolInfo>[];
    String? cursor;
    // 防御异常服务无限翻页。
    for (var page = 0; page < 20; page++) {
      final result = await _request('tools/list', {
        if (cursor != null) 'cursor': cursor,
      }, timeout: listTimeout);
      for (final item in result['tools'] as List? ?? const []) {
        if (item is! Map) continue;
        final tool = McpToolInfo.fromJson(Map<String, dynamic>.from(item));
        if (tool.name.isNotEmpty) tools.add(tool);
      }
      final next = result['nextCursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    return McpServerSnapshot(serverName: _serverName, tools: tools);
  }

  Future<McpToolCallResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    await _ensureInitialized();
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    }, timeout: callTimeout);
    return McpToolCallResult(
      text: flattenToolResult(result),
      isError: result['isError'] == true,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  /// 把 CallToolResult 压成文本：文本块原样拼接，其它块给出简短占位，
  /// 只有结构化结果时输出 JSON。
  static String flattenToolResult(Map<String, dynamic> result) {
    final parts = <String>[];
    for (final block in result['content'] as List? ?? const []) {
      if (block is! Map) continue;
      switch (block['type']) {
        case 'text':
          parts.add((block['text'] ?? '').toString());
        case 'resource':
          final resource = block['resource'];
          if (resource is Map && resource['text'] != null) {
            parts.add(resource['text'].toString());
          } else if (resource is Map) {
            parts.add('[资源 ${resource['uri'] ?? ''}]');
          }
        case 'resource_link':
          parts.add('[链接 ${block['name'] ?? ''} ${block['uri'] ?? ''}]'.trim());
        case 'image':
          parts.add('[图片 ${block['mimeType'] ?? ''}，未转给模型]');
        case 'audio':
          parts.add('[音频 ${block['mimeType'] ?? ''}，未转给模型]');
      }
    }
    var text = parts.join('\n').trim();
    if (text.isEmpty && result['structuredContent'] != null) {
      text = jsonEncode(result['structuredContent']);
    }
    if (text.length > maxResultChars) {
      text = '${text.substring(0, maxResultChars)}\n…（结果过长，已截断）';
    }
    return text;
  }

  Future<void> _ensureInitialized() {
    if (_sessionId != null || _negotiatedVersion != null) {
      return Future.value();
    }
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    final result = await _send(
      'initialize',
      {
        'protocolVersion': protocolVersion,
        'capabilities': const <String, dynamic>{},
        'clientInfo': {'name': 'AIcove', 'version': clientVersion},
      },
      timeout: listTimeout,
      captureSession: true,
    );
    _negotiatedVersion = (result['protocolVersion'] ?? protocolVersion)
        .toString();
    final info = result['serverInfo'];
    if (info is Map) {
      _serverName = (info['title'] ?? info['name'] ?? '').toString();
    }
    await _notify('notifications/initialized');
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
  }) async {
    try {
      return await _send(method, params, timeout: timeout);
    } on _SessionExpired {
      _sessionId = null;
      _negotiatedVersion = null;
      await _ensureInitialized();
      return _send(method, params, timeout: timeout);
    }
  }

  Map<String, String> _headers() => {
    ...headers,
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    if (_negotiatedVersion != null) 'MCP-Protocol-Version': _negotiatedVersion!,
    if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
  };

  Future<void> _notify(String method) async {
    final request = http.Request('POST', Uri.parse(url))
      ..headers.addAll(_headers())
      ..body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    final response = await _client.send(request).timeout(listTimeout);
    await response.stream.drain<void>();
    if (response.statusCode >= 400) {
      throw McpException('服务拒绝了 $method（HTTP ${response.statusCode}）');
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    bool captureSession = false,
  }) async {
    final id = _nextId++;
    final hadSession = _sessionId != null;
    final request = http.Request('POST', Uri.parse(url))
      ..headers.addAll(_headers())
      ..body = jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw McpException('连接超时（$method）');
    } catch (e) {
      throw McpException('无法连接到 MCP 服务：$e');
    }
    if (response.statusCode == 404 && hadSession) {
      await response.stream.drain<void>();
      throw const _SessionExpired();
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      await response.stream.drain<void>();
      throw McpException('鉴权失败（HTTP ${response.statusCode}），请检查令牌或请求头');
    }
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      throw McpException(
        'MCP 服务返回 HTTP ${response.statusCode}'
        '${body.trim().isEmpty ? '' : '：${_snippet(body)}'}',
      );
    }
    if (captureSession) {
      final session = response.headers['mcp-session-id'];
      if (session != null && session.isNotEmpty) _sessionId = session;
    }
    final contentType = response.headers['content-type'] ?? '';
    final Map<String, dynamic> message;
    try {
      message = contentType.contains('text/event-stream')
          ? await _readSse(response.stream, id).timeout(timeout)
          : _decodeObject(await response.stream.bytesToString());
    } on TimeoutException {
      throw McpException('等待响应超时（$method）');
    } on McpException {
      rethrow;
    } catch (e) {
      throw McpException('读取响应失败（$method）：$e');
    }
    final error = message['error'];
    if (error is Map) {
      throw McpException('MCP 错误：${error['message'] ?? error['code']}');
    }
    final result = message['result'];
    if (result is! Map) throw McpException('响应缺少 result（$method）');
    return Map<String, dynamic>.from(result);
  }

  Future<Map<String, dynamic>> _readSse(
    Stream<List<int>> stream,
    int id,
  ) async {
    final data = StringBuffer();
    // 服务端可能先推送通知或服务端请求，只取与本次 id 对应的响应。
    Map<String, dynamic>? matchingResponse() {
      final payload = data.toString();
      data.clear();
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map && decoded['id'] == id) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
      return null;
    }

    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || data.isEmpty) continue;
      final response = matchingResponse();
      if (response != null) return response;
    }
    if (data.isNotEmpty) {
      final response = matchingResponse();
      if (response != null) return response;
    }
    throw const McpException('事件流结束但没有收到响应');
  }

  static Map<String, dynamic> _decodeObject(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw McpException('响应不是 JSON：${_snippet(body)}');
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw McpException('响应格式不对：${_snippet(body)}');
  }

  static String _snippet(String text) {
    final trimmed = text.trim();
    return trimmed.length <= 200 ? trimmed : '${trimmed.substring(0, 200)}…';
  }
}

class _SessionExpired implements Exception {
  const _SessionExpired();
}

/// 按连接器复用客户端，保持 MCP 会话；地址或请求头变化时换新客户端。
class McpClientPool {
  McpClientPool._();

  static final McpClientPool instance = McpClientPool._();

  final _clients = <String, (String, McpHttpClient)>{};

  McpHttpClient clientFor(McpConnector connector) {
    final fingerprint = jsonEncode([
      connector.url.trim(),
      connector.requestHeaders,
    ]);
    final cached = _clients[connector.id];
    if (cached != null && cached.$1 == fingerprint) return cached.$2;
    cached?.$2.close();
    final client = McpHttpClient(
      url: connector.url.trim(),
      headers: connector.requestHeaders,
    );
    _clients[connector.id] = (fingerprint, client);
    return client;
  }

  void remove(String connectorId) => _clients.remove(connectorId)?.$2.close();
}
