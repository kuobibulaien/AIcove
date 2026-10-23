import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../settings/app_settings.dart';
import '../data/workspace_store.dart';
import '../domain/workspace_errors.dart';
import '../workspace_providers.dart';
import 'webapp_ai.dart';
import 'webapp_server.dart';

/// Shared by launch actions and the workspace undo action.
final webAppServerProvider = FutureProvider<WebAppServer>((ref) async {
  final store = await ref.watch(workspaceStoreProvider.future);
  final server = WebAppServer(
    store: store,
    dataDir: store.root.parent,
    aiChat: createWebAppAiChat(
      loadSettings: () => ref.read(appSettingsProvider.future),
    ),
  );
  ref.onDispose(() => unawaited(server.close()));
  return server;
});

final webAppLauncherProvider = FutureProvider<WebAppLauncher>((ref) async {
  final server = await ref.watch(webAppServerProvider.future);
  return WebAppLauncher(store: server.store, server: server);
});

class WebAppOpenResult {
  const WebAppOpenResult({required this.uri, required this.portChanged});
  final Uri uri;
  final bool portChanged;
}

class WebAppOpenException implements Exception {
  const WebAppOpenException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class WebAppLauncher {
  WebAppLauncher({
    required this.store,
    required this.server,
    Future<bool> Function(Uri)? openExternal,
  }) : _openExternal = openExternal ?? _launch;

  final WorkspaceStore store;
  final WebAppServer server;
  final Future<bool> Function(Uri) _openExternal;

  static Future<bool> _launch(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<WebAppOpenResult> open(String wsId, String path) async {
    final page = WebAppServer.checkedPath(path);
    if (!WebAppServer.isHtml(page)) {
      throw const WebAppOpenException('not_html', '只能运行 .html 或 .htm 文件');
    }
    if (await store.get(wsId) == null || await store.stat(wsId, page) == null) {
      throw const WebAppOpenException('not_found', '文件不存在');
    }
    WebAppServer.savePathFor(page);
    final prefix = await store.readRange(wsId, page, offset: 0, length: 2);
    if (WebAppServer.isUtf16(prefix)) {
      throw const WebAppOpenException(
        'unsupported_encoding',
        '这个网页是 UTF-16 编码，只支持 UTF-8 编码的网页',
      );
    }
    final started = await server.start();
    server.allow(wsId);
    await server.activate();
    final uri = Uri.parse(
      'http://${wsId.toLowerCase()}.localhost:${started.port}/${page.split('/').map(Uri.encodeComponent).join('/')}',
    );
    if (!await _openExternal(uri)) {
      throw const WebAppOpenException(
        'launch_failed',
        '没能打开浏览器，请检查是否设置了默认浏览器',
      );
    }
    return WebAppOpenResult(uri: uri, portChanged: started.portChanged);
  }

  /// [open] for agent tools: failures surface as tool errors.
  Future<Uri> openForAgent(String wsId, String path) async {
    try {
      return (await open(wsId, path)).uri;
    } on WebAppOpenException catch (error) {
      throw WorkspaceException(error.code, error.message);
    }
  }
}
