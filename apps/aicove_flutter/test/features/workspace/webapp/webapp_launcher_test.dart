import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/services/android_keep_alive_manager.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_errors.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_launcher.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:aicove_flutter/src/features/workspace/workspace_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late WorkspaceStore store;
  late WebAppServer server;
  late String ws;
  late List<Uri> opened;
  late List<bool> transitions;
  late WebAppLauncher launcher;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('launcher_test');
    store = await WorkspaceStore.open(Directory('${root.path}/ws'));
    ws = (await store.create(name: 'Launch')).id;
    opened = [];
    transitions = [];
    server = WebAppServer(
      store: store,
      dataDir: root,
      candidatePorts: [0],
      shimSource: '',
      setWebAppActive: (active) async => transitions.add(active),
    );
    launcher = WebAppLauncher(
      store: store,
      server: server,
      openExternal: (uri) async {
        expect(transitions.last, isTrue);
        opened.add(uri);
        return true;
      },
    );
  });
  tearDown(() async {
    await server.close();
    await store.close();
    await root.delete(recursive: true);
  });

  Future<void> put(String path, List<int> bytes) =>
      store.write(ws, path, bytes, runId: 'setup');
  Matcher code(String value) =>
      isA<WebAppOpenException>().having((e) => e.code, 'code', value);

  test(
    'validates encoding, extension, existence and derived save path before starting',
    () async {
      await put('text.txt', [65]);
      await put('utf16.html', [255, 254, 65, 0]);
      await put('big-endian.htm', [254, 255, 0, 65]);
      await expectLater(
        launcher.open(ws, 'text.txt'),
        throwsA(code('not_html')),
      );
      await expectLater(
        launcher.open(ws, 'missing.html'),
        throwsA(code('not_found')),
      );
      await expectLater(
        launcher.open('missing', 'text.html'),
        throwsA(code('not_found')),
      );
      for (final path in ['utf16.html', 'big-endian.htm']) {
        await expectLater(
          launcher.open(ws, path),
          throwsA(code('unsupported_encoding')),
        );
      }
      await expectLater(
        launcher.open(ws, '.AICOVE/game.html'),
        throwsA(isA<WorkspaceException>()),
      );
      final path =
          '${'a' * 95}.html'; // HTML name fits, derived .save.json does not.
      await put(path, [65]);
      await expectLater(
        launcher.open(ws, path),
        throwsA(isA<WorkspaceException>()),
      );
      expect(opened, isEmpty);
      expect(transitions, isEmpty);
      expect(await File('${root.path}/webapp/port').exists(), isFalse);
    },
  );

  test(
    'encodes path segments, starts idempotently, and returns browser URL',
    () async {
      const path = '游戏/好 游戏.HTML';
      await put(path, utf8.encode('<!doctype html>'));
      final result = await launcher.open(ws, path);
      expect(result.uri.scheme, 'http');
      expect(result.uri.host, '$ws.localhost');
      expect(result.uri.pathSegments, ['游戏', '好 游戏.HTML']);
      expect(result.uri.toString(), contains('%E6%B8%B8%E6%88%8F'));
      expect(result.portChanged, isFalse);
      expect(opened, [result.uri]);
      expect((await launcher.open(ws, path)).uri, result.uri);
      expect(transitions, [true]);
    },
  );

  test('browser refusal surfaces a launch error', () async {
    await put('game.html', [65]);
    launcher = WebAppLauncher(
      store: store,
      server: server,
      openExternal: (_) async => false,
    );
    await expectLater(
      launcher.open(ws, 'game.html'),
      throwsA(code('launch_failed')),
    );
  });

  test(
    'providers share the server and bundled shim loads through the asset manifest',
    () async {
      final container = ProviderContainer(
        overrides: [workspaceStoreProvider.overrideWith((ref) async => store)],
      );
      final shared = await container.read(webAppServerProvider.future);
      try {
        final fromProvider = await container.read(
          webAppLauncherProvider.future,
        );
        expect(identical(fromProvider.server, shared), isTrue);
        expect(identical(shared.store, store), isTrue);
        expect(shared.dataDir.path, root.path);
        final text = await rootBundle.loadString('assets/webapp/shim.js');
        expect(text, contains('aicove.webapp.save.v1'));
        expect(text, contains('navigator.locks.request'));
      } finally {
        await shared.close();
        container.dispose();
      }
    },
  );

  group('Android web app method channel', () {
    const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    test(
      'passes independent true/false without generation leases or status polling',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await AndroidKeepAliveManager.setWebAppActive(true);
        await AndroidKeepAliveManager.setWebAppActive(false);
        expect(calls.map((c) => c.method), [
          'setWebAppActive',
          'setWebAppActive',
        ]);
        expect(calls.map((c) => c.arguments), [
          {'active': true},
          {'active': false},
        ]);
        expect(
          AndroidKeepAliveStatus.fromMap({'webAppActive': true}).webAppActive,
          isTrue,
        );
      },
    );
    test('non-Android is a no-op', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await AndroidKeepAliveManager.setWebAppActive(true);
      expect(calls, isEmpty);
    });
    test(
      'native failure is returned to server for logging and retry',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'denied'),
        );
        await expectLater(
          AndroidKeepAliveManager.setWebAppActive(true),
          throwsA(isA<PlatformException>()),
        );
      },
    );
  });
}
