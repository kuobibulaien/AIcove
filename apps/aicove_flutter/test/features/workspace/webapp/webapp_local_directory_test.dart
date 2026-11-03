import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/data/local_workspace_files.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_errors.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_launcher.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture, local;
  late WorkspaceStore store;
  late WebAppServer server;
  late WebAppLauncher launcher;
  late HttpClient client;
  setUp(() async {
    fixture = await Directory(
      'test/features/workspace/webapp',
    ).createTemp('local_');
    local = await Directory('${fixture.path}/project').create();
    await File(
      '${local.path}/index.html',
    ).writeAsString('<!doctype html>hello');
    store = await WorkspaceStore.open(Directory('${fixture.path}/store'));
    server = WebAppServer(
      store: store,
      dataDir: Directory('${fixture.path}/host'),
      candidatePorts: [0],
      shimSource: '// shim',
      aiChat: (_) async => 'local reply',
      setWebAppActive: (_) async {},
    );
    launcher = WebAppLauncher(
      store: store,
      server: server,
      openExternal: (_) async => true,
    );
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    await store.close();
    await fixture.delete(recursive: true);
  });
  Future<(int, String)> send(
    Uri uri,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      Uri.parse('http://127.0.0.1:${uri.port}$path'),
    );
    request.headers.set('host', '${uri.host}:${uri.port}');
    if (body != null) {
      request.headers.set('origin', 'http://${uri.host}:${uri.port}');
      request.headers.set('sec-fetch-site', 'same-origin');
    }
    headers.forEach(request.headers.set);
    if (body != null) request.write(body);
    final response = await request.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }

  test(
    'serves local files and save conflicts without workspace metadata',
    () async {
      final uri = await launcher.openLocalDirectoryForAgent(
        local.absolute.path,
        'index.html',
      );
      expect(
        (await send(uri, '/index.html')).$2,
        contains('/__aicove/shim.js'),
      );
      final run =
          jsonDecode(
                (await send(uri, '/__aicove/run?page=index.html', body: '')).$2,
              )['runId']
              as String;
      const payload =
          '{"format":"aicove.webapp.save.v1","localStorage":{"x":"y"}}';
      final headers = {'x-aicove-run': run, 'x-aicove-base': ''};
      expect(
        (await send(
          uri,
          '/__aicove/save?page=index.html',
          headers: headers,
          body: payload,
        )).$1,
        200,
      );
      expect(
        await File('${local.path}/index.save.json').readAsString(),
        payload,
      );
      expect(
        (await send(
          uri,
          '/__aicove/save?page=index.html',
          headers: headers,
          body: payload.replaceAll('"y"', '"z"'),
        )).$1,
        409,
      );
      expect(
        (await local.list().toList())
            .map((e) => e.uri.pathSegments.last)
            .toSet(),
        {'index.html', 'index.save.json'},
      );
      expect(await store.list(), isEmpty);
    },
  );
  test('rejects escapes, directory listing and protected store roots', () async {
    await File('${fixture.path}/secret').writeAsString('secret');
    await Link('${local.path}/escape').create('../secret');
    await Directory('${local.path}/empty').create();
    await Link('${local.path}/outside-dir').create('..');
    final uri = await launcher.openLocalDirectoryForAgent(
      local.absolute.path,
      'index.html',
    );
    for (final path in [
      '/escape',
      '/outside-dir/secret',
      '/empty/',
      '/%2e%2e%2fsecret',
      '/%252e%252e/secret',
    ]) {
      expect((await send(uri, path)).$1, 404, reason: path);
    }
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, uri.port);
    socket.write(
      'GET /%2e%2e/secret HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nConnection: close\r\n\r\n',
    );
    final raw = await utf8.decoder.bind(socket).join();
    expect(raw, startsWith('HTTP/1.1 404'));
    socket.destroy();
    for (final path in [store.root.absolute.path, fixture.absolute.path]) {
      await expectLater(
        launcher.openLocalDirectoryForAgent(path, 'index.html'),
        throwsA(isA<WorkspaceException>()),
      );
    }
  });
  test(
    'native names, stable origin, AI bridge and concurrent save revisions',
    () async {
      final page = '${'n' * 110} 游戏.html';
      await File('${local.path}/$page').writeAsString('<!doctype html>native');
      final uri = await launcher.openLocalDirectoryForAgent(
        local.absolute.path,
        page,
      );
      expect(
        await launcher.openLocalDirectoryForAgent(local.absolute.path, page),
        uri,
      );
      expect((await send(uri, uri.path)).$1, 200);
      final query = 'page=${Uri.encodeComponent(page)}';
      final ai = await send(
        uri,
        '/__aicove/ai/chat?$query',
        body: '{"messages":[{"role":"user","content":"hello"}]}',
      );
      expect(ai.$1, 200);
      expect(jsonDecode(ai.$2)['text'], 'local reply');
      final run =
          jsonDecode(
                (await send(uri, '/__aicove/run?$query', body: '')).$2,
              )['runId']
              as String;
      final replies = await Future.wait([
        for (final value in ['one', 'two'])
          send(
            uri,
            '/__aicove/save?$query',
            headers: {'x-aicove-run': run, 'x-aicove-base': ''},
            body:
                '{"format":"aicove.webapp.save.v1","localStorage":{"x":"$value"}}',
          ),
      ]);
      expect(replies.map((r) => r.$1).toSet(), {200, 409});
      final state = jsonDecode((await send(uri, '/__aicove/state?$query')).$2);
      expect(state['revision'], isNotEmpty);
      expect(
        state['text'],
        await File('${local.path}/${'n' * 110} 游戏.save.json').readAsString(),
      );
    },
  );
  test('save refuses existing and broken symbolic link targets', () async {
    final uri = await launcher.openLocalDirectoryForAgent(
      local.absolute.path,
      'index.html',
    );
    final run =
        jsonDecode(
              (await send(uri, '/__aicove/run?page=index.html', body: '')).$2,
            )['runId']
            as String;
    final secret = File('${fixture.path}/secret');
    await secret.writeAsString('original');
    for (final destination in ['../secret', '../absent']) {
      final link = await Link(
        '${local.path}/index.save.json',
      ).create(destination);
      expect(
        (await send(
          uri,
          '/__aicove/save?page=index.html',
          headers: {'x-aicove-run': run, 'x-aicove-base': ''},
          body: '{"format":"aicove.webapp.save.v1","localStorage":{}}',
        )).$1,
        404,
      );
      await link.delete();
    }
    expect(await secret.readAsString(), 'original');
    expect(await File('${fixture.path}/absent').exists(), isFalse);
  });
  test(
    'native tool and web saves share revisions and leave no failed-write artifacts',
    () async {
      final files = LocalWorkspaceFiles(
        local.absolute.path,
        protectedRoot: store.root.path,
        beforeCommit: () {},
      );
      const initial =
          '{"format":"aicove.webapp.save.v1","localStorage":{"x":"initial"}}';
      final seed = await files.write('index.save.json', utf8.encode(initial));
      final uri = await launcher.openLocalDirectoryForAgent(
        local.absolute.path,
        'index.html',
      );
      final run =
          jsonDecode(
                (await send(uri, '/__aicove/run?page=index.html', body: '')).$2,
              )['runId']
              as String;
      const toolText =
          '{"format":"aicove.webapp.save.v1","localStorage":{"x":"tool"}}';
      const webText =
          '{"format":"aicove.webapp.save.v1","localStorage":{"x":"web"}}';
      final results = await Future.wait([
        files
            .write(
              'index.save.json',
              utf8.encode(toolText),
              expectedRevision: seed.revision,
            )
            .then(
              (_) => 200,
              onError: (Object e) {
                expect(
                  e,
                  isA<WorkspaceException>().having(
                    (e) => e.code,
                    'code',
                    'revision_mismatch',
                  ),
                );
                return 409;
              },
            ),
        send(
          uri,
          '/__aicove/save?page=index.html',
          headers: {'x-aicove-run': run, 'x-aicove-base': seed.revision},
          body: webText,
        ).then((reply) => reply.$1),
      ]);
      expect(results.toSet(), {200, 409});
      final retained = await files.read('index.save.json');
      expect(
        utf8.decode(retained.$1),
        results.first == 200 ? toolText : webText,
      );
      final denied = LocalWorkspaceFiles(
        local.absolute.path,
        protectedRoot: store.root.path,
        beforeCommit: () =>
            throw const WorkspaceException('cancelled', 'test cancellation'),
      );
      await expectLater(
        denied.write(
          'index.save.json',
          utf8.encode(initial),
          expectedRevision: retained.$2,
        ),
        throwsA(
          isA<WorkspaceException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect((await files.read('index.save.json')).$2, retained.$2);
      expect(
        (await local.list().toList())
            .map((e) => e.uri.pathSegments.last)
            .toSet(),
        {'index.html', 'index.save.json'},
      );
    },
  );
  test(
    'FIFO files are rejected instead of blocking HTTP or page launch',
    () async {
      final fifo = '${local.absolute.path}/pipe.html';
      expect((await Process.run('mkfifo', [fifo])).exitCode, 0);
      await expectLater(
        launcher.openLocalDirectoryForAgent(local.absolute.path, 'pipe.html'),
        throwsA(
          isA<WorkspaceException>().having((e) => e.code, 'code', 'not_found'),
        ),
      );
      final uri = await launcher.openLocalDirectoryForAgent(
        local.absolute.path,
        'index.html',
      );
      expect((await send(uri, '/pipe.html')).$1, 404);
      final saveFifo = '${local.absolute.path}/index.save.json';
      expect((await Process.run('mkfifo', [saveFifo])).exitCode, 0);
      final state = await send(uri, '/__aicove/state?page=index.html');
      expect(state.$1, 200);
      expect(jsonDecode(state.$2)['text'], isNull);
    },
    skip: Platform.isWindows,
  );
  test(
    'reports invalid root, missing page and UTF16 before browser launch',
    () async {
      await File('${local.path}/utf16.html').writeAsBytes([255, 254, 65, 0]);
      for (final entry in [
        ('relative', 'index.html', 'invalid_path'),
        (local.absolute.path, 'missing.html', 'not_found'),
        (local.absolute.path, 'utf16.html', 'unsupported_encoding'),
      ]) {
        await expectLater(
          launcher.openLocalDirectoryForAgent(entry.$1, entry.$2),
          throwsA(
            isA<WorkspaceException>().having((e) => e.code, 'code', entry.$3),
          ),
        );
      }
    },
  );
}
