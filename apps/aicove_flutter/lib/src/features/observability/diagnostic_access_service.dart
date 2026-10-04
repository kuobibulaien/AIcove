import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/storage/device_credential_storage.dart';
import 'diagnostic_access_port.dart';
import 'diagnostic_bundle.dart';
import 'diagnostic_runtime_identity.dart';
import 'storage_inventory.dart';

class DiagnosticAccessService implements DiagnosticAccessPort {
  DiagnosticAccessService({
    this.port = 48631,
    Future<String> Function()? tokenLoader,
    Future<Uint8List> Function()? storageBuilder,
    Future<Uint8List> Function()? bundleBuilder,
  }) : _bundleBuilder = bundleBuilder,
       _storageBuilder = storageBuilder,
       _tokenLoader = tokenLoader ?? _persistentToken;

  static final instance = DiagnosticAccessService();
  final int port;
  final Future<String> Function() _tokenLoader;
  final Future<Uint8List> Function()? _bundleBuilder;
  final Future<Uint8List> Function()? _storageBuilder;
  final _session = ValueNotifier<DiagnosticAccessSession?>(null);
  HttpServer? _server;
  Timer? _retry;
  bool _automatic = false;
  bool _busy = false;
  Future<void>? _starting;

  @override
  ValueListenable<DiagnosticAccessSession?> get session => _session;

  @override
  Future<Uint8List> exportBundle() async {
    if (_busy) throw StateError('诊断正在生成，请稍后重试');
    _busy = true;
    try {
      if (_bundleBuilder != null) return await _bundleBuilder();
      final path = '${(await getApplicationDocumentsDirectory()).path}/logs';
      return await Isolate.run(() => createDiagnosticBundle(path));
    } finally {
      _busy = false;
    }
  }

  /// 启动不阻塞首屏；端口或安全存储暂不可用时自动重试。
  Future<Uint8List> _exportStorage() async {
    if (_busy) throw StateError('诊断正在生成，请稍后重试');
    _busy = true;
    try {
      if (_storageBuilder != null) return await _storageBuilder();
      // Android support directory is files/ inside this application's sandbox.
      // Never scan the parent of a desktop documents/support directory.
      if (!Platform.isAndroid) throw UnsupportedError('Android only');
      final root = (await getApplicationSupportDirectory()).parent.path;
      final build = await readDiagnosticRuntimeIdentity();
      final inventory = await Isolate.run(() => createStorageInventory(root));
      inventory['build'] = build;
      return Uint8List.fromList(utf8.encode(jsonEncode(inventory)));
    } finally {
      _busy = false;
    }
  }

  void startAutomatically() {
    _automatic = true;
    _retry?.cancel();
    unawaited(
      start().catchError((Object _) {
        if (_automatic) {
          _retry = Timer(const Duration(seconds: 5), startAutomatically);
        }
      }),
    );
  }

  @override
  Future<void> start() {
    if (_session.value != null) return Future.value();
    return _starting ??= _open().whenComplete(() => _starting = null);
  }

  Future<void> _open() async {
    final token = await _tokenLoader();
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    _session.value = DiagnosticAccessSession(server.port, token);
    if (Platform.isAndroid) unawaited(_publishToAdbShell(token));
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) => unawaited(_recover()),
    );
  }

  Future<void> _recover() async {
    final automatic = _automatic;
    await stop();
    if (automatic) startAutomatically();
  }

  /// 交给 native 的 DUMP 权限 ContentProvider，电脑插线后由采集脚本经 adb 自取。
  static Future<void> _publishToAdbShell(String token) async {
    try {
      await const MethodChannel(
        'com.example.aicove_flutter/diagnostic_identity',
      ).invokeMethod<void>('publishAccessToken', token);
    } catch (_) {
      // 旧壳或通道异常时仍可用诊断页面提供的带凭证命令。
    }
  }

  static Future<String> _persistentToken() {
    const storage = DeviceCredentialStorage();
    const key = 'diagnostic_access_token_v1';
    return loadDiagnosticAccessToken(
      read: () => storage.read(key: key),
      write: (token) => storage.write(key: key, value: token),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      final current = _session.value;
      if (current == null ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer ${current.token}') {
        response.statusCode = HttpStatus.unauthorized;
      } else if (request.method != 'GET' ||
          !const {'/v1/bundle', '/v1/storage'}.contains(request.uri.path) ||
          request.uri.hasQuery) {
        response.statusCode = HttpStatus.notFound;
      } else if (_busy) {
        response.statusCode = HttpStatus.conflict;
      } else {
        final bytes = request.uri.path == '/v1/storage'
            ? await _exportStorage()
            : await exportBundle();
        response.headers.contentType = ContentType.json;
        response.contentLength = bytes.length;
        response.add(bytes);
      }
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* Client disconnected. */
      }
    }
  }

  @override
  Future<void> stop() async {
    _automatic = false;
    _retry?.cancel();
    _retry = null;
    await _starting;
    _session.value = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

/// 成功持久化后才开放读取，使应用重启不会悄悄更换电脑命令。
Future<String> loadDiagnosticAccessToken({
  required Future<String?> Function() read,
  required Future<void> Function(String) write,
}) async {
  final existing = await read();
  if (existing != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(existing)) {
    return existing;
  }
  final random = Random.secure();
  final token = base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
  await write(token);
  return token;
}
