import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class Reply {
  Reply(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final List<int> bytes;
  String get text => utf8.decode(bytes);
  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  late Directory root;
  late WorkspaceStore store;
  late WebAppServer server;
  late String ws;
  late HttpClient client;
  late DateTime now;
  late List<bool> activity;

  Future<void> put(String path, List<int> bytes, {String run = 'setup'}) async {
    final exists = await store.stat(ws, path);
    await store.write(
      ws,
      path,
      bytes,
      expectedRevision: exists == null ? null : (await store.read(ws, path)).$2,
      runId: run,
    );
  }

  Future<Reply> send(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? host,
    List<int>? body,
    bool origin = true,
    bool fetchSite = true,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    request.headers.set('Host', host ?? '$ws.localhost:${server.port}');
    if (method == 'POST') {
      if (origin) {
        request.headers.set('Origin', 'http://$ws.localhost:${server.port}');
      }
      if (fetchSite) request.headers.set('Sec-Fetch-Site', 'same-origin');
      request.headers.contentType = ContentType.json;
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(response.headers.value('cache-control'), 'no-store');
    expect(response.headers.value('x-content-type-options'), 'nosniff');
    expect(response.headers.value('referrer-policy'), 'no-referrer');
    expect(
      response.headers.value('cross-origin-resource-policy'),
      'same-origin',
    );
    expect(
      response.headers.value('content-security-policy'),
      WebAppServer.contentSecurityPolicy,
    );
    expect(response.headers.value('access-control-allow-origin'), isNull);
    return Reply(response.statusCode, response.headers, bytes);
  }

  Future<int> rawStatus(String path) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    socket.write(
      'GET $path HTTP/1.1\r\nHost: $ws.localhost:${server.port}\r\nConnection: close\r\n\r\n',
    );
    final bytes = await socket.fold<List<int>>([], (a, b) => a..addAll(b));
    socket.destroy();
    final text = utf8.decode(bytes);
    expect(
      text.toLowerCase(),
      contains('cross-origin-resource-policy: same-origin'),
    );
    expect(text.toLowerCase(), contains('content-security-policy: '));
    return int.parse(text.split(' ')[1]);
  }

  String api(String action, {String page = 'game.html', String suffix = ''}) =>
      '/__aicove/$action?page=${Uri.encodeComponent(page)}$suffix';
  Future<String> run({String page = 'game.html'}) async =>
      (await send(api('run', page: page), method: 'POST')).json['runId']
          as String;
  Future<Reply> save(
    String id,
    String text, {
    String base = '',
    String page = 'game.html',
  }) => send(
    api('save', page: page),
    method: 'POST',
    headers: {'X-AIcove-Run': id, 'X-AIcove-Base': base},
    body: utf8.encode(text),
  );
  String saveText(String value) =>
      '{"format":"aicove.webapp.save.v1","localStorage":{"value":"$value"}}';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webapp_test');
    store = await WorkspaceStore.open(
      Directory(p.join(root.path, 'workspaces')),
    );
    ws = (await store.create(name: 'Web')).id;
    await put(
      'game.html',
      utf8.encode('<!doctype html><script>game()</script>'),
    );
    now = DateTime.utc(2026);
    activity = [];
    server = WebAppServer(
      store: store,
      dataDir: root,
      candidatePorts: [0],
      clock: () => now,
      shimSource: '/* test shim */',
      setWebAppActive: (active) async => activity.add(active),
    );
    await server.start();
    server.allow(ws);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await store.close();
    await root.delete(recursive: true);
  });

  test(
    'Host, registration, methods, Origin, fetch metadata, service worker',
    () async {
      for (final host in [
        'localhost:${server.port}',
        'evil.test:${server.port}',
        '$ws.localhost:1',
        'evil.$ws.localhost:${server.port}',
      ]) {
        expect((await send('/game.html', host: host)).status, 403);
      }
      expect(
        (await send(
          '/game.html',
          host: 'unregistered.localhost:${server.port}',
        )).status,
        404,
      );
      server.allow('absent');
      expect(
        (await send(
          '/game.html',
          host: 'absent.localhost:${server.port}',
        )).status,
        404,
      );
      expect(
        (await send(
          '/game.html',
          headers: {'Service-Worker': 'script'},
        )).status,
        403,
      );
      for (final method in ['OPTIONS', 'PUT', 'DELETE', 'POST']) {
        expect((await send('/game.html', method: method)).status, 405);
      }
      expect((await send(api('run'), method: 'GET')).status, 405);
      for (final action in ['run', 'save']) {
        expect(
          (await send(api(action), method: 'POST', origin: false)).status,
          403,
        );
        expect(
          (await send(api(action), method: 'POST', fetchSite: false)).status,
          403,
        );
        expect(
          (await send(
            api(action),
            method: 'POST',
            headers: {'Origin': 'https://evil.test'},
          )).status,
          403,
        );
        expect(
          (await send(
            api(action),
            method: 'POST',
            headers: {'Sec-Fetch-Site': 'cross-site'},
          )).status,
          403,
        );
        expect((await send(api(action), method: 'OPTIONS')).status, 405);
      }
      final head = await send('/game.html', method: 'HEAD');
      expect(head.status, 200);
      expect(head.bytes, isEmpty);
      expect((await send(api('shim.js'), method: 'HEAD')).bytes, isEmpty);
      expect((await send(api('state'), method: 'HEAD')).bytes, isEmpty);
    },
  );

  test(
    'path boundaries reject unsafe segments; Uri-normalized dots remain confined',
    () async {
      await put('.AICOVE/secret', [1]);
      for (final path in [
        '/%2Fgame.html',
        '/games%2Fgame.html',
        '/games%5Cgame.html',
        '/.aicove/workspace.json',
        '/.AICOVE/secret',
        '/games/.AiCoVe/a',
        '/%00',
        '/games//a',
      ]) {
        expect(await rawStatus(path), 404, reason: path);
      }
      // dart:io parses the target as Uri before exposing it; dot segments have
      // already disappeared. These aliases stay inside the registered workspace.
      for (final path in [
        '/../game.html',
        '/%2e%2e/game.html',
        '/games/%2E%2E/game.html',
        '/./game.html',
        '/%2e/game.html',
      ]) {
        expect(await rawStatus(path), 200);
      }
      expect(
        (await send(api('state', page: '.aicove/workspace.json'))).status,
        404,
      );
      expect((await send(api('state', page: '../game.html'))).status, 404);
      expect((await send(api('state', page: 'missing.html'))).status, 404);
      expect((await send(api('state', page: 'game.txt'))).status, 404);
      // A literal percent is decoded exactly once, never treated as traversal.
      await put('%2e%2e/game.html', utf8.encode('literal'));
      expect((await send('/%252e%252e/game.html')).status, 200);
    },
  );

  test('MIME, static bytes, directory indexes and non-ASCII paths', () async {
    final files = <String, String>{
      'main.js': 'text/javascript; charset=utf-8',
      'main.css': 'text/css; charset=utf-8',
      'state.json': 'application/json; charset=utf-8',
      'image.svg': 'image/svg+xml; charset=utf-8',
      'data.unknownext': 'application/octet-stream',
    };
    for (final entry in files.entries) {
      await put(entry.key, [1, 2, 3]);
      final response = await send('/${entry.key}');
      expect(response.status, 200);
      expect(response.bytes, [1, 2, 3]);
      expect(response.headers.value('content-type'), entry.value);
    }
    await put('index.htm', utf8.encode('root'));
    await put('games/index.html', utf8.encode('nested'));
    await put('games/index.htm', utf8.encode('fallback'));
    expect((await send('/')).text, endsWith('root'));
    expect((await send('/games/')).text, endsWith('nested'));
    expect((await send('/missing/')).status, 404);
    await put('游戏/好 游戏.htm', utf8.encode('中文'));
    expect(
      (await send(
        '/${['游戏', '好 游戏.htm'].map(Uri.encodeComponent).join('/')}',
      )).text,
      endsWith('中文'),
    );
  });

  test(
    'single ranges, invalid ranges, HTML ignores range, large streaming',
    () async {
      await put('test.bin', List.generate(100, (i) => i));
      for (final (range, first, last) in [
        ('bytes=2-5', 2, 5),
        ('bytes=98-', 98, 99),
        ('bytes=-3', 97, 99),
        ('bytes=98-1000', 98, 99),
        ('bytes=-1000', 0, 99),
      ]) {
        final response = await send('/test.bin', headers: {'Range': range});
        expect(response.status, 206);
        expect(
          response.bytes,
          List.generate(last - first + 1, (i) => i + first),
        );
        expect(
          response.headers.value('content-range'),
          'bytes $first-$last/100',
        );
      }
      for (final range in [
        'bytes=9-2',
        'bytes=100-',
        'bytes=-0',
        'bytes=-',
        'bytes=0-1,4-5',
        'items=0-1',
      ]) {
        final response = await send('/test.bin', headers: {'Range': range});
        expect(response.status, 416);
        expect(response.headers.value('content-range'), 'bytes */100');
      }
      expect(
        (await send('/game.html', headers: {'Range': 'bytes=0-3'})).status,
        200,
      );
      await put('empty.bin', []);
      expect(
        (await send('/empty.bin', headers: {'Range': 'bytes=0-'})).status,
        416,
      );
      final bytes = List.generate((5 << 20) + 17, (i) => i % 251);
      await put('large.bin', bytes);
      final response = await send('/large.bin');
      expect(response.status, 200);
      expect(response.bytes, bytes);
      final partial = await send(
        '/large.bin',
        headers: {'Range': 'bytes=1048570-1048590'},
      );
      expect(partial.status, 206);
      expect(partial.bytes, bytes.sublist(1048570, 1048591));
      final bigHtml = utf8.encode(
        '<!--${'x' * (4 << 20)}--><!doctype html><p>done',
      );
      await put('large.html', bigHtml);
      final html = await send('/large.html');
      expect(html.status, 200);
      expect(
        html.text.replaceFirst(
          RegExp(r'<script src="/__aicove/shim.js\?page=large.html"></script>'),
          '',
        ),
        utf8.decode(bigHtml),
      );
      expect(html.text.indexOf('<script'), greaterThan(4 << 20));
    },
  );

  test(
    'HTML insertion preserves all original bytes, including legacy encodings',
    () async {
      const script = '<script src="/__aicove/shim.js?page=game.html"></script>';
      final fixtures = <(List<int>, int)>[
        (utf8.encode('<!doctype html><p>x'), 15),
        (utf8.encode('<!DOCTYPE html><p>x'), 15),
        (utf8.encode(' \n<!--first--><!--next-->\t<!DoCtYpE html><p>x'), 41),
        (utf8.encode('<!--unclosed <!doctype html><p>x'), 0),
        (utf8.encode('<p>no doctype'), 0),
        ([], 0),
        ([239, 187, 191, ...utf8.encode('<!doctype html><p>x')], 18),
        ([239, 187, 191, 60, 112, 62, 0x81, 0x82], 3),
      ];
      for (final (bytes, expectedOffset) in fixtures) {
        await put('game.html', bytes);
        final response = await send('/game.html');
        expect(response.status, 200);
        expect(response.headers.value('content-type'), 'text/html');
        expect(response.bytes, [
          ...bytes.take(expectedOffset),
          ...ascii.encode(script),
          ...bytes.skip(expectedOffset),
        ], reason: '$bytes at $expectedOffset');
      }
      for (final bom in [
        [255, 254],
        [254, 255],
      ]) {
        final bytes = [...bom, 60, 0, 112, 0];
        await put('game.html', bytes);
        expect((await send('/game.html')).bytes, bytes);
      }
    },
  );

  test(
    'boot and state are read-only, known omits text, save retains raw JSON',
    () async {
      final first = await send(api('shim.js'));
      expect(first.status, 200);
      expect(first.text, startsWith('window.__AICOVE_BOOT__ = '));
      expect(first.text, contains('"savePath":"game.save.json"'));
      expect(first.text, contains('"text":null'));
      expect(first.text, endsWith('/* test shim */'));
      expect(await store.stat(ws, 'game.save.json'), isNull);
      expect(
        (await store.runs(ws)).where((r) => r.runId.startsWith('webapp-')),
        isEmpty,
      );
      final state = await send(api('state', suffix: '&known='));
      expect(state.json, {'revision': ''});
      final id = await run();
      const raw =
          ' { "format":"aicove.webapp.save.v1", "localStorage":{"n":{"value":1.0},"big":9007199254740993} }\n';
      final saved = await save(id, raw);
      expect(saved.status, 200);
      final revision = saved.json['revision'] as String;
      expect((await store.read(ws, 'game.save.json')).$1, utf8.encode(raw));
      final same = await save(id, raw, base: 'obsolete');
      expect(same.status, 200);
      expect(same.json['revision'], revision);
      expect(
        (await store.runs(ws)).where((r) => r.runId == id).single.opCount,
        1,
      );
      expect((await send(api('state', suffix: '&known=$revision'))).json, {
        'revision': revision,
      });
      expect((await send(api('state'))).json, {
        'revision': revision,
        'text': raw,
      });
      expect((await send(api('shim.js'))).text, contains(jsonEncode(raw)));
      final conflict = await save(id, saveText('later'));
      expect(conflict.status, 409);
      expect(conflict.json, {
        'error': 'conflict',
        'revision': revision,
        'text': raw,
      });
      final updated = await save(id, saveText('later'), base: revision);
      expect(updated.status, 200);
    },
  );

  test(
    'bad saves, too large, and run closed or bound to a different page/workspace',
    () async {
      final id = await run();
      for (final text in [
        '{',
        '[]',
        '{"format":"wrong","localStorage":{}}',
        '{"format":"aicove.webapp.save.v1","localStorage":[]}',
      ]) {
        final response = await save(id, text);
        expect(response.status, 400);
        expect(response.json['error'], 'bad_save');
      }
      expect(
        (await send(
          api('save'),
          method: 'POST',
          headers: {'X-AIcove-Run': id},
          body: utf8.encode(saveText('x')),
        )).status,
        400,
      );
      expect(
        (await save(id, 'x' * (WebAppServer.maxSaveBytes + 1))).status,
        413,
      );
      // Chunked request enforces the same limit without Content-Length.
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}${api('save')}'),
      );
      request.headers
        ..set('Host', '$ws.localhost:${server.port}')
        ..set('Origin', 'http://$ws.localhost:${server.port}')
        ..set('Sec-Fetch-Site', 'same-origin')
        ..set('X-AIcove-Run', id)
        ..set('X-AIcove-Base', '');
      for (var i = 0; i < 17; i++) {
        request.add(List.filled(1 << 20, 120));
      }
      final response = await request.close();
      expect(response.statusCode, 413);
      await response.drain<void>();
      await put('other.html', utf8.encode('other'));
      expect(
        (await save(id, saveText('x'), page: 'other.html')).json['error'],
        'run_closed',
      );
      final another = (await store.create(name: 'Other')).id;
      await store.write(another, 'game.html', [60, 112, 62], runId: 'setup');
      server.allow(another);
      expect(
        (await send(
          api('save'),
          method: 'POST',
          host: '$another.localhost:${server.port}',
          headers: {
            'Origin': 'http://$another.localhost:${server.port}',
            'X-AIcove-Run': id,
            'X-AIcove-Base': '',
          },
          body: utf8.encode(saveText('x')),
        )).json['error'],
        'run_closed',
      );
      await run();
      expect((await save(id, saveText('x'))).json['error'], 'run_closed');
      expect((await save('unknown', saveText('x'))).status, 409);
    },
  );

  test(
    'store busy returns 503 and undo waits for all accepted writes',
    () async {
      final id = await run();
      final entered = Completer<void>(), release = Completer<void>();
      store.afterIntent = (op) async {
        if (op.runId != id) return;
        entered.complete();
        await release.future;
      };
      final pending = save(id, saveText('first'));
      await entered.future;
      final busy = await save(id, saveText('second'));
      expect(busy.status, 503);
      expect(busy.json['error'], 'busy');
      var undone = false;
      final undo = server.undoRun(ws, id).then((r) {
        undone = true;
        return r;
      });
      expect((await send(api('run'), method: 'POST')).status, 503);
      expect((await save(id, saveText('third'))).status, 503);
      expect(undone, isFalse);
      release.complete();
      expect((await pending).status, 200);
      store.afterIntent = null;
      expect((await undo).undone, 1);
      expect(await store.stat(ws, 'game.save.json'), isNull);
      expect((await save(id, saveText('old'))).json['error'], 'run_closed');
      expect((await send(api('run'), method: 'POST')).status, 200);
    },
  );

  test(
    'one play session is one undoable run, including initial save restoration',
    () async {
      await put('game.save.json', utf8.encode(saveText('before')));
      final before = (await store.read(ws, 'game.save.json')).$2;
      final id = await run();
      final a = await save(id, saveText('a'), base: before);
      final b = await save(
        id,
        saveText('b'),
        base: a.json['revision'] as String,
      );
      expect(b.status, 200);
      expect(
        (await store.runs(ws)).where((r) => r.runId == id).single.opCount,
        2,
      );
      final otherId = await run(page: 'game.html');
      await put('other.html', [1]);
      final secondPage = await run(page: 'other.html');
      expect((await server.undoRun(ws, id)).undone, 2);
      expect(
        utf8.decode((await store.read(ws, 'game.save.json')).$1),
        saveText('before'),
      );
      expect((await save(otherId, saveText('x'))).json['error'], 'run_closed');
      expect(
        (await save(
          secondPage,
          saveText('x'),
          page: 'other.html',
        )).json['error'],
        'run_closed',
      );
    },
  );

  test(
    'idle expiry releases keep-alive and new traffic reacquires it',
    () async {
      await server.activate();
      expect(activity, [true]);
      now = now.add(const Duration(seconds: 119));
      await server.checkIdle();
      expect(activity, [true]);
      now = now.add(const Duration(seconds: 1));
      await server.checkIdle();
      expect(activity, [true, false]);
      await send(api('state'));
      await Future<void>.delayed(Duration.zero);
      expect(activity, [true, false, true]);
    },
  );

  test(
    'recorded port is preferred; concurrent starts consume notice once',
    () async {
      final first = server.port;
      await server.close();
      server = WebAppServer(
        store: store,
        dataDir: root,
        candidatePorts: [first, 0],
        shimSource: '',
        setWebAppActive: (_) async {},
      );
      final restarted = await server.start();
      expect(restarted.port, first);
      expect(restarted.portChanged, isFalse);
      await server.close();
      final occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        first,
      );
      try {
        server = WebAppServer(
          store: store,
          dataDir: root,
          candidatePorts: [first, 0],
          shimSource: '',
          setWebAppActive: (_) async {},
        );
        final results = await Future.wait([server.start(), server.start()]);
        expect(results.first.port, isNot(first));
        expect(results.map((r) => r.portChanged), [true, false]);
        expect((await server.start()).portChanged, isFalse);
        expect(
          int.parse(
            await File(p.join(root.path, 'webapp', 'port')).readAsString(),
          ),
          server.port,
        );
      } finally {
        await occupied.close();
      }
    },
  );

  test('IPv6 port collision rejects the entire candidate port', () async {
    ServerSocket occupied;
    try {
      occupied = await ServerSocket.bind(
        InternetAddress.loopbackIPv6,
        0,
        v6Only: true,
      );
    } on SocketException {
      markTestSkipped('Host does not support IPv6');
      return;
    }
    try {
      await server.close();
      server = WebAppServer(
        store: store,
        dataDir: root,
        candidatePorts: [occupied.port, 0],
        shimSource: '',
        setWebAppActive: (_) async {},
      );
      final result = await server.start();
      expect(result.port, isNot(occupied.port));
      server.allow(ws);
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv6,
        result.port,
      );
      socket.write(
        'GET /game.html HTTP/1.1\r\nHost: $ws.localhost:${result.port}\r\nConnection: close\r\n\r\n',
      );
      final text = await utf8.decoder.bind(socket).join();
      socket.destroy();
      expect(text, startsWith('HTTP/1.1 200'));
    } finally {
      await occupied.close();
    }
  });
}
