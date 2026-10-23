import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/app_logger.dart';
import '../../../core/services/android_keep_alive_manager.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_errors.dart';
import '../domain/workspace_models.dart';
import '../domain/workspace_path_rules.dart';
import 'webapp_ai.dart';

class WebAppStartResult {
  const WebAppStartResult({required this.port, required this.portChanged});
  final int port;
  final bool portChanged;
}

/// Process-local loopback host. The launcher and undo UI must share this instance.
class WebAppServer {
  WebAppServer({
    required this.store,
    required this.dataDir,
    this.candidatePorts = const [
      47823,
      47824,
      47825,
      47826,
      47827,
      47828,
      47829,
      47830,
      47831,
      47832,
      47833,
      47834,
      47835,
      47836,
      47837,
      47838,
      47839,
      47840,
      47841,
      47842,
    ],
    DateTime Function()? clock,
    this.shimSource,
    this.aiChat,
    Future<void> Function(bool)? setWebAppActive,
  }) : _clock = clock ?? DateTime.now,
       _setWebAppActive =
           setWebAppActive ?? AndroidKeepAliveManager.setWebAppActive;

  static const quota = 5 << 20;
  static const maxSaveBytes = 16 << 20;
  static const _chunkSize = 1 << 20;
  static const maxAiCalls = 2;
  // Pages may load and call the internet and other local ports (ADR0109
  // 补充二); workers stay local and nothing may frame a page.
  static const contentSecurityPolicy =
      "default-src 'self' data: blob: http: https:; script-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: http: https:; style-src 'self' 'unsafe-inline' data: blob: http: https:; img-src 'self' data: blob: http: https:; media-src 'self' data: blob: http: https:; font-src 'self' data: blob: http: https:; connect-src 'self' data: blob: http: https: ws: wss:; worker-src 'self' data: blob:; frame-src 'self' data: blob: http: https:; form-action 'self'; base-uri 'self'; frame-ancestors 'self'";

  final WorkspaceStore store;
  final Directory dataDir;
  final List<int> candidatePorts;
  final DateTime Function() _clock;
  final Future<void> Function(bool) _setWebAppActive;
  final String? shimSource;

  /// Model calls for pages (ADR0109); null answers `no_model`.
  final WebAppAiChat? aiChat;
  String? _loadedShimSource;
  final _aiCalls = <String, int>{};
  final _servers = <HttpServer>[];
  final _allowed = <String, String>{};
  final _runs = <String, _Run>{};
  final _undoing = <String>{};
  final _writes = <String, int>{};
  final _drained = <String, Completer<void>>{};
  Future<WebAppStartResult>? _starting;
  Timer? _idleTimer;
  DateTime? _lastRequest;
  bool _active = false;
  Future<void> _activityQueue = Future.value();

  int get port => _servers.first.port;

  /// Concurrent opens share one bind; a changed-port notice is consumed once.
  Future<WebAppStartResult> start() async {
    if (_servers.isNotEmpty) {
      return WebAppStartResult(port: port, portChanged: false);
    }
    if (_starting != null) {
      final result = await _starting!;
      return WebAppStartResult(port: result.port, portChanged: false);
    }
    final pending = _bind();
    _starting = pending;
    try {
      return await pending;
    } finally {
      _starting = null;
    }
  }

  Future<WebAppStartResult> _bind() async {
    _loadedShimSource ??=
        shimSource ?? await rootBundle.loadString('assets/webapp/shim.js');
    final record = File(p.join(dataDir.path, 'webapp', 'port'));
    int? previous;
    if (await record.exists()) {
      previous = int.tryParse((await record.readAsString()).trim());
    }
    final candidates = {
      if (candidatePorts.contains(previous)) previous!,
      ...candidatePorts,
    };
    SocketException? lastError;
    for (final candidate in candidates) {
      HttpServer v4;
      try {
        v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, candidate);
      } on SocketException catch (error) {
        lastError = error;
        continue;
      }
      HttpServer? v6;
      try {
        v6 = await HttpServer.bind(
          InternetAddress.loopbackIPv6,
          v4.port,
          v6Only: true,
        );
      } on SocketException catch (error) {
        final code = error.osError?.errorCode;
        if ([48, 98, 10048].contains(code) ||
            (code == -1 &&
                (error.osError?.message.contains('shared flag to bind()') ??
                    false))) {
          await v4.close(force: true);
          lastError = error;
          continue;
        }
        // EAFNOSUPPORT / EPROTONOSUPPORT / EADDRNOTAVAIL on supported hosts.
        if (![47, 43, 49, 97, 93, 99, 10047, 10043, 10049].contains(code)) {
          await v4.close(force: true);
          rethrow;
        }
      }
      try {
        await record.parent.create(recursive: true);
        await record.writeAsString('${v4.port}\n', flush: true);
      } catch (_) {
        await v4.close(force: true);
        await v6?.close(force: true);
        rethrow;
      }
      _servers.addAll([v4, if (v6 != null) v6]);
      for (final server in _servers) {
        server.listen((request) => unawaited(_handle(request)));
      }
      _idleTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(checkIdle());
      });
      return WebAppStartResult(
        port: port,
        portChanged: previous != null && previous != port,
      );
    }
    throw lastError ?? StateError('No loopback port available');
  }

  void allow(String wsId) => _allowed[wsId.toLowerCase()] = wsId;

  /// Also called before handing control to the browser, while Android is foreground.
  Future<void> activate() {
    _lastRequest = _clock();
    return _activity(true);
  }

  Future<void> checkIdle() async {
    final last = _lastRequest;
    if (last != null &&
        _clock().difference(last) >= const Duration(minutes: 2)) {
      await _activity(false);
    }
  }

  Future<void> _activity(bool desired) {
    final pending = _activityQueue.then((_) async {
      if (_active == desired) return;
      try {
        await _setWebAppActive(desired);
        _active = desired;
      } catch (error) {
        AppLogger.warning('WebAppServer', 'Web app keep-alive failed: $error');
      }
    });
    _activityQueue = pending;
    return pending;
  }

  Future<void> close() async {
    if (_starting != null) await _starting;
    _idleTimer?.cancel();
    for (final server in _servers) {
      await server.close(force: true);
    }
    _servers.clear();
    _allowed.clear();
    _runs.clear();
    await _activity(false);
  }

  /// Stops all web writers in this workspace before undoing any kind of run.
  Future<WorkspaceUndoResult> undoRun(String wsId, String runId) async {
    if (!_undoing.add(wsId)) {
      throw const WorkspaceException.busy('Web app undo in progress');
    }
    try {
      _runs.removeWhere((_, run) => run.ws == wsId);
      if ((_writes[wsId] ?? 0) > 0) {
        await (_drained[wsId] ??= Completer<void>()).future;
      }
      return await store.undoRun(wsId, runId);
    } finally {
      _undoing.remove(wsId);
    }
  }

  void _headers(HttpResponse response) {
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Referrer-Policy', 'no-referrer')
      ..set('Cross-Origin-Resource-Policy', 'same-origin')
      ..set('Content-Security-Policy', contentSecurityPolicy);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _headers(response);
    try {
      final host = request.headers.value('host') ?? '';
      final suffix = '.localhost:$port';
      if (!host.endsWith(suffix)) throw const _HttpError(403);
      final label = host.substring(0, host.length - suffix.length);
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(label)) throw const _HttpError(403);
      final ws = _allowed[label];
      if (ws == null || await store.get(ws) == null) {
        throw const _HttpError(404);
      }
      if (request.headers.value('service-worker')?.toLowerCase() == 'script') {
        throw const _HttpError(403);
      }
      final api = request.uri.path.startsWith('/__aicove/');
      if (request.method != 'GET' &&
          request.method != 'HEAD' &&
          !(request.method == 'POST' && api)) {
        throw const _HttpError(405);
      }
      if (request.method == 'POST' &&
          (request.headers.value('origin') != 'http://$host' ||
              request.headers.value('sec-fetch-site') != 'same-origin')) {
        throw const _HttpError(403);
      }
      _lastRequest = _clock();
      unawaited(_activity(true));
      if (api) {
        await _api(request, ws);
      } else {
        await _static(request, ws);
      }
    } on _HttpError catch (error) {
      response.statusCode = error.status;
      if (request.method == 'POST') response.persistentConnection = false;
      if (error.body != null) _json(response, error.body!);
    } on WorkspaceException catch (error) {
      response.statusCode = error.code == 'busy' ? 503 : 404;
      if (error.code == 'busy') _json(response, {'error': 'busy'});
    } on FormatException {
      response.statusCode = 404;
    } on FileSystemException {
      response.statusCode = 404;
    } catch (error, stack) {
      AppLogger.warning('WebAppServer', '$error\n$stack');
      try {
        response.statusCode = 500;
      } catch (_) {
        /* Already streaming. */
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* Browser disconnected. */
      }
    }
  }

  static String checkedPath(String path) {
    final normalized = WorkspacePathRules.normalize(path);
    if (normalized.split('/').any((s) => s.toLowerCase() == '.aicove')) {
      throw const WorkspaceException.invalidPath('Host paths cannot be served');
    }
    return normalized;
  }

  static bool isHtml(String path) =>
      ['.html', '.htm'].contains(p.extension(path).toLowerCase());

  static String savePathFor(String page) =>
      checkedPath('${p.withoutExtension(page)}.save.json');

  Future<void> _static(HttpRequest request, String ws) async {
    final segments = request.uri.pathSegments.toList();
    final directory =
        request.uri.path.isEmpty || request.uri.path.endsWith('/');
    if (directory && segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    for (final segment in segments) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains('/') ||
          segment.contains('\\') ||
          segment.contains('\x00')) {
        throw const _HttpError(404);
      }
    }
    var path = segments.isEmpty ? '' : checkedPath(segments.join('/'));
    WorkspaceFile? file;
    if (directory) {
      for (final index in ['index.html', 'index.htm']) {
        final candidate = checkedPath(path.isEmpty ? index : '$path/$index');
        file = await store.stat(ws, candidate);
        if (file != null) {
          path = candidate;
          break;
        }
      }
    } else {
      if (path.isEmpty) throw const _HttpError(404);
      file = await store.stat(ws, path);
    }
    if (file == null) throw const _HttpError(404);
    final small = file.size <= 4 << 20 ? (await store.read(ws, path)).$1 : null;
    final header =
        small ?? await store.readRange(ws, path, offset: 0, length: 32);
    final html = isHtml(path);
    var mime = html
        ? 'text/html'
        : lookupMimeType(path, headerBytes: header.take(32).toList()) ??
              'application/octet-stream';
    if (!html &&
        (mime.startsWith('text/') ||
            [
              'application/javascript',
              'application/json',
              'image/svg+xml',
            ].contains(mime))) {
      mime += '; charset=utf-8';
    }
    final response = request.response;
    response.headers.set('Content-Type', mime);
    var start = 0, end = file.size;
    final range = request.headers.value('range');
    if (!html) {
      response.headers.set('Accept-Ranges', 'bytes');
      if (range != null) {
        final parsed = _range(range, file.size);
        if (parsed == null) {
          response.headers.set('Content-Range', 'bytes */${file.size}');
          throw const _HttpError(416);
        }
        (start, end) = parsed;
        response.statusCode = 206;
        response.headers.set(
          'Content-Range',
          'bytes $start-${end - 1}/${file.size}',
        );
      }
    }
    int? insertion;
    List<int> script = const [];
    if (html && !isUtf16(header)) {
      insertion = await _insertion(ws, path, file.size, small);
      script = ascii.encode(
        '<script src="/__aicove/shim.js?page=${Uri.encodeComponent(path)}"></script>',
      );
    }
    response.contentLength = end - start + script.length;
    if (request.method == 'HEAD') return;
    await for (final chunk in _chunks(ws, path, start, end, small)) {
      if (insertion != null &&
          insertion >= start &&
          insertion <= start + chunk.length) {
        final offset = insertion - start;
        response.add(chunk.sublist(0, offset));
        response.add(script);
        response.add(chunk.sublist(offset));
        insertion = null;
      } else {
        response.add(chunk);
      }
      start += chunk.length;
      await response.flush();
    }
    if (insertion != null) response.add(script); // Empty HTML file.
  }

  Stream<List<int>> _chunks(
    String ws,
    String path,
    int start,
    int end,
    Uint8List? small,
  ) async* {
    if (small != null) {
      yield Uint8List.sublistView(small, start, end);
      return;
    }
    for (var offset = start; offset < end; offset += _chunkSize) {
      final bytes = await store.readRange(
        ws,
        path,
        offset: offset,
        length: (end - offset).clamp(0, _chunkSize),
      );
      if (bytes.isEmpty) {
        throw const FileSystemException('File changed while streaming');
      }
      yield bytes;
    }
  }

  static bool isUtf16(List<int> bytes) =>
      bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff));

  Future<int> _insertion(
    String ws,
    String path,
    int size,
    Uint8List? small,
  ) async {
    final scanner = _HtmlPreamble();
    await for (final chunk in _chunks(ws, path, 0, size, small)) {
      for (final byte in chunk) {
        final result = scanner.add(byte);
        if (result != null) return result;
      }
    }
    return scanner.fallback;
  }

  static (int, int)? _range(String value, int size) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || size == 0) return null;
    final a = match[1]!, b = match[2]!;
    if (a.isEmpty) {
      final suffix = int.tryParse(b);
      if (suffix == null || suffix <= 0) return null;
      return ((size - suffix).clamp(0, size), size);
    }
    final first = int.tryParse(a),
        last = b.isEmpty ? size - 1 : int.tryParse(b);
    if (first == null || last == null || first >= size || last < first) {
      return null;
    }
    return (first, (last + 1).clamp(0, size));
  }

  Future<({String revision, String? text, List<int>? bytes})> _state(
    String ws,
    String path,
  ) async {
    try {
      final (bytes, revision) = await store.read(ws, path);
      return (
        revision: revision,
        text: utf8.decode(bytes, allowMalformed: true),
        bytes: bytes,
      );
    } on WorkspaceException catch (error) {
      if (error.code != 'not_found') rethrow;
      return (revision: '', text: null, bytes: null);
    }
  }

  void _json(HttpResponse response, Map<String, Object?> body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }

  Future<void> _api(HttpRequest request, String ws) async {
    final route = request.uri.path.substring('/__aicove/'.length);
    if (route.startsWith('v1/')) {
      await _openAi(request, ws, route.substring(3));
      return;
    }
    final page = checkedPath(request.uri.queryParameters['page'] ?? '');
    if (!isHtml(page) || await store.stat(ws, page) == null) {
      throw const _HttpError(404);
    }
    final savePath = savePathFor(page);
    if (request.method == 'GET' || request.method == 'HEAD') {
      if (route != 'shim.js' && route != 'state') throw const _HttpError(405);
      final state = await _state(ws, savePath);
      if (route == 'state') {
        final body = <String, Object?>{
          'revision': state.revision,
          if (state.revision != request.uri.queryParameters['known'])
            'text': state.text,
        };
        if (request.method != 'HEAD') _json(request.response, body);
      } else {
        request.response.headers.set(
          'Content-Type',
          'application/javascript; charset=utf-8',
        );
        if (request.method != 'HEAD') {
          request.response.write(
            'window.__AICOVE_BOOT__ = ${jsonEncode({'page': page, 'savePath': savePath, 'revision': state.revision, 'text': state.text, 'quota': quota})};\n$_loadedShimSource',
          );
        }
      }
      return;
    }
    if (route == 'ai/chat') {
      await _ai(request, ws);
      return;
    }
    if (route == 'run') {
      if (_undoing.contains(ws)) throw const _HttpError(503, {'error': 'busy'});
      _runs.removeWhere((_, run) => run.ws == ws && run.page == page);
      final id = 'webapp-${const Uuid().v4()}';
      _runs[id] = _Run(ws, page);
      _json(request.response, {'runId': id});
      return;
    }
    if (route != 'save') throw const _HttpError(404);
    if (_undoing.contains(ws)) throw const _HttpError(503, {'error': 'busy'});
    final runId = request.headers.value('x-aicove-run') ?? '';
    final run = _runs[runId];
    if (run == null || run.ws != ws || run.page != page) {
      throw const _HttpError(409, {'error': 'run_closed'});
    }
    // Count the entire accepted request, including body reads and revision checks.
    _writes[ws] = (_writes[ws] ?? 0) + 1;
    try {
      final bytes = await _body(request, maxSaveBytes);
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map ||
            decoded['format'] != 'aicove.webapp.save.v1' ||
            decoded['localStorage'] is! Map) {
          throw const FormatException();
        }
      } on FormatException {
        throw const _HttpError(400, {'error': 'bad_save'});
      }
      final base = request.headers.value('x-aicove-base');
      if (base == null) throw const _HttpError(400, {'error': 'bad_save'});
      final state = await _state(ws, savePath);
      if (state.text != null && _equalBytes(bytes, state.bytes!)) {
        _json(request.response, {'revision': state.revision});
        return;
      }
      try {
        final file = await store.write(
          ws,
          savePath,
          bytes,
          expectedRevision: base.isEmpty ? null : base,
          runId: runId,
        );
        _json(request.response, {'revision': file.revision});
      } on WorkspaceException catch (error) {
        if (error.code != 'revision_mismatch') rethrow;
        final current = await _state(ws, savePath);
        // A simultaneous identical retry may have committed after the first read.
        if (current.text != null && _equalBytes(bytes, current.bytes!)) {
          _json(request.response, {'revision': current.revision});
        } else {
          throw _HttpError(409, {
            'error': 'conflict',
            'revision': current.revision,
            'text': current.text,
          });
        }
      }
    } finally {
      _writes[ws] = _writes[ws]! - 1;
      if (_writes[ws] == 0) _drained.remove(ws)?.complete();
    }
  }

  static Future<Uint8List> _body(HttpRequest request, int limit) async {
    final body = BytesBuilder(copy: false);
    var tooLarge = request.contentLength > limit;
    // Drain rejected bodies without retaining them. Closing an unread body can
    // reset the connection before a browser receives the 413 response.
    await for (final chunk in request) {
      if (tooLarge) continue;
      if (body.length + chunk.length > limit) {
        tooLarge = true;
        body.clear();
      } else {
        body.add(chunk);
      }
    }
    if (tooLarge) throw const _HttpError(413, {'error': 'too_large'});
    return body.takeBytes();
  }

  Future<void> _ai(HttpRequest request, String ws) async {
    try {
      final text = await _aiText(request, ws, WebAppAiRequest.fromJson);
      _json(request.response, {'text': text});
    } on WebAppAiException catch (error) {
      throw _HttpError(_aiStatus(error.code), {
        'error': error.code,
        'message': error.message,
      });
    }
  }

  /// OpenAI-compatible surface (`/__aicove/v1`) for third-party pages that
  /// only let users fill in an API base URL. Same checks and model as
  /// [_ai]; streaming requests get the whole reply as one chunk.
  Future<void> _openAi(HttpRequest request, String ws, String route) async {
    final response = request.response;
    if (route == 'models' && request.method != 'POST') {
      if (request.method == 'GET') {
        _json(response, {
          'object': 'list',
          'data': [
            {'id': openAiModel, 'object': 'model', 'owned_by': 'aicove'},
          ],
        });
      }
      return;
    }
    if (route != 'chat/completions' || request.method != 'POST') {
      throw const _HttpError(404);
    }
    var stream = false;
    try {
      final text = await _aiText(request, ws, (body) {
        stream = body is Map && body['stream'] == true;
        return WebAppAiRequest.fromOpenAi(body);
      });
      final id = 'chatcmpl-aicove-${const Uuid().v4()}';
      final created = _clock().millisecondsSinceEpoch ~/ 1000;
      Map<String, Object?> envelope(
        String object,
        Map<String, Object?> choice,
      ) => {
        'id': id,
        'object': object,
        'created': created,
        'model': openAiModel,
        'choices': [
          {'index': 0, ...choice},
        ],
      };
      if (!stream) {
        _json(
          response,
          envelope('chat.completion', {
            'message': {'role': 'assistant', 'content': text},
            'finish_reason': 'stop',
          }),
        );
        return;
      }
      response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      for (final chunk in [
        envelope('chat.completion.chunk', {
          'delta': {'role': 'assistant', 'content': text},
          'finish_reason': null,
        }),
        envelope('chat.completion.chunk', {
          'delta': <String, Object?>{},
          'finish_reason': 'stop',
        }),
      ]) {
        response.write('data: ${jsonEncode(chunk)}\n\n');
      }
      response.write('data: [DONE]\n\n');
    } on WebAppAiException catch (error) {
      throw _HttpError(_aiStatus(error.code), {
        'error': {
          'message': error.message,
          'type': error.code,
          'code': error.code,
        },
      });
    }
  }

  static const openAiModel = 'aicove-default';

  static int _aiStatus(String code) => switch (code) {
    'bad_request' => 400,
    'busy' => 429,
    'no_model' => 503,
    _ => 502,
  };

  Future<String> _aiText(
    HttpRequest request,
    String ws,
    WebAppAiRequest Function(Object? body) parse,
  ) async {
    final chat = aiChat;
    if ((_aiCalls[ws] ?? 0) >= maxAiCalls) {
      await request.drain<void>();
      throw const WebAppAiException('busy', '同时最多 $maxAiCalls 个 AI 请求，请等上一个回来');
    }
    _aiCalls[ws] = (_aiCalls[ws] ?? 0) + 1;
    try {
      final bytes = await _body(request, WebAppAiRequest.maxBodyBytes);
      if (chat == null) {
        throw const WebAppAiException('no_model', 'AIcove 还没有配置默认聊天模型');
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const WebAppAiException('bad_request', '请求体不是合法的 JSON');
      }
      return await chat(parse(decoded));
    } finally {
      _aiCalls[ws] = _aiCalls[ws]! - 1;
    }
  }

  static bool _equalBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Run {
  const _Run(this.ws, this.page);
  final String ws, page;
}

class _HttpError implements Exception {
  const _HttpError(this.status, [this.body]);
  final int status;
  final Map<String, Object?>? body;
}

/// Incremental byte scanner: even a very long leading comment stays bounded.
class _HtmlPreamble {
  int _position = 0;
  int fallback = 0;
  String _token = '';
  String _tail = '';
  String _mode = 'bom';

  int? add(int byte) {
    _position++;
    if (_mode == 'bom') {
      if (_position <= 3 && byte == [0xef, 0xbb, 0xbf][_position - 1]) {
        if (_position == 3) {
          fallback = 3;
          _mode = 'space';
        }
        return null;
      }
      if (_position > 1) return fallback;
      _mode = 'space';
    }
    final char = String.fromCharCode(byte).toLowerCase();
    if (_mode == 'comment') {
      _tail = '$_tail$char';
      if (_tail.length > 3) _tail = _tail.substring(_tail.length - 3);
      if (_tail == '-->') {
        _mode = 'space';
        _tail = '';
      }
      return null;
    }
    if (_mode == 'doctype') return byte == 62 ? _position : null;
    if (_mode == 'space') {
      if ([32, 9, 10, 12, 13].contains(byte)) return null;
      _mode = 'token';
      _token = '';
    }
    _token += char;
    if (_token == '<!--') {
      _mode = 'comment';
      return null;
    }
    if (_token == '<!doctype') {
      _mode = 'doctype';
      return null;
    }
    if (!'<!--'.startsWith(_token) && !'<!doctype'.startsWith(_token)) {
      return fallback;
    }
    return null;
  }
}
