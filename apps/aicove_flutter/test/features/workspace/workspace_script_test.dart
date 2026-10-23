import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:aicove_flutter/src/core/network/public_network.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_script.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_read_only_mount.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:image/image.dart' as img;

class _Mount implements WorkspaceReadOnlyMount {
  @override
  Future<Map<String, MountedWorkspaceFile>> files() async => {
    'a.png': MountedWorkspaceFile(
      size: 1,
      revision: 'revision',
      updatedAt: DateTime(2026),
      read: () async => Uint8List(1),
    ),
  };
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace_script_');
    store = await WorkspaceStore.open(root);
    ws = (await store.create(name: 'scripts')).id;
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  WorkspaceScript script({
    ScriptToolAccess? tools,
    bool Function()? cancelled,
    PublicNetwork Function()? network,
  }) => WorkspaceScript(
    store: store,
    workspace: ws,
    runId: 'script_run',
    tools: tools,
    isCancelled: cancelled,
    networkFactory: network,
  );
  Future<ToolOutput> call(Map<String, dynamic> args) =>
      WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'script_run',
        enableScripts: true,
      ).tools().firstWhere((t) => t.name == 'codemode').invoke(args);

  test('codemode accepts only code and manages its own optional deadline', () async {
    final tool=WorkspaceToolset(store:store,workspaceIds:{ws},runId:'r',enableScripts:true).tools().firstWhere((t)=>t.name=='codemode');
    expect(tool.managesDeadline,true); expect(tool.executionTimeout,isNull);
    expect((tool.inputSchema!['properties'] as Map).keys,['code']);
    expect((await call({'code':'text(42);'})).text,contains('42'));
    expect(()=>call({'path':'script.js'}),throwsFormatException);
  });
  test(
    'await fetch then byte write records this run and is undoable',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.write('hello 网络');
        await r.response.close();
      });
      try {
        final out =
            await script(
              network: () => PublicNetwork(
                resolve: (_) async => [InternetAddress('8.8.8.8')],
                connect: (_, _) => Socket.startConnect(
                  InternetAddress.loopbackIPv4,
                  server.port,
                ),
              ),
            ).run('''
const r = await fetch('http://public.example:${server.port}/');
text(await r.text());
await ws.writeBytes('download.bin', new Uint8Array(await r.arrayBuffer()));
''');
        expect(out.isError, isFalse, reason: out.text);
        expect(out.text, 'hello 网络');
        expect(
          utf8.decode((await store.read(ws, 'download.bin')).$1),
          'hello 网络',
        );
        expect((await store.undoRun(ws, 'script_run')).undone, 1);
        expect(await store.stat(ws, 'download.bin'), isNull);
      } finally {
        await server.close(force: true);
      }
    },
  );
  for (final bytes in [
    4 * 1024 * 1024 - 1,
    4 * 1024 * 1024,
    4 * 1024 * 1024 + 1,
  ]) {
    test('byte bridge chunk boundary $bytes', () async {
      final out = await script().run('''
await ws.writeBytes('bytes.bin',new Uint8Array($bytes).fill(7));
const b=await ws.readBytes('bytes.bin',{length:$bytes});
text([b.length,b.slice(0,4),b.slice(-4)]);
''');
      expect(
        out.isError,
        bytes > WorkspaceScript.maxChunkBytes,
        reason: out.text,
      );
      if (bytes <= WorkspaceScript.maxChunkBytes) {
        final expected = base64Encode(Uint8List(bytes)..fillRange(0, bytes, 7));
        expect(
          out.text,
          jsonEncode([
            expected.length,
            expected.substring(0, 4),
            expected.substring(expected.length - 4),
          ]),
        );
      } else {
        expect(await store.stat(ws, 'bytes.bin'), isNull);
      }
    });
  }
  for (final bytes in [
    4 * 1024 * 1024 - 1,
    4 * 1024 * 1024,
    4 * 1024 * 1024 + 1,
  ]) {
    test('read chunk limit independently rejects $bytes', () async {
      await store.write(
        ws,
        'source',
        Uint8List(4 * 1024 * 1024 + 1),
        runId: 'setup',
      );
      final out = await script().run(
        'text((await ws.readBytes("source",{length:$bytes})).length);',
      );
      expect(
        out.isError,
        bytes > WorkspaceScript.maxChunkBytes,
        reason: out.text,
      );
      if (bytes <= WorkspaceScript.maxChunkBytes) {
        expect(out.text, '${((bytes + 2) ~/ 3) * 4}');
      }
    });
  }
  test(
    'byte offsets append, preserve tails, truncate, reject holes and traversal',
    () async {
      final out = await script().run('''
await ws.writeBytes('bytes',new Uint8Array([1,2,3]));
await ws.writeBytes('bytes',new Uint8Array([4,5]),{offset:3,truncate:false});
await ws.writeBytes('bytes',new Uint8Array([9]),{offset:1,truncate:false});
text(await ws.readBytes('bytes',{offset:1,length:3}));
await ws.writeBytes('bytes',new Uint8Array([8]),{offset:2,truncate:true});
''');
      expect(out.isError, isFalse, reason: out.text);
      expect(out.text, base64Encode([9, 3, 4]));
      expect((await store.read(ws, 'bytes')).$1, [1, 9, 8]);
      for (final code in [
        "await ws.writeBytes('bytes',new Uint8Array([0]),{offset:20})",
        "await ws.writeBytes('../escape',new Uint8Array([0]))",
        "await ws.writeBytes('.aicove/x',new Uint8Array([0]))",
      ]) {
        expect((await script().run(code)).isError, isTrue);
      }
    },
  );
  test(
    'byte view is read-only, including mixed case; rejected before any intent',
    () async {
      store.registerReadOnlyMount(ws, 'stickers', _Mount());
      for (final path in ['stickers/a.png', 'Stickers/a.png']) {
        final out = await script().run(
          "await ws.writeBytes('$path',new Uint8Array([1]));",
        );
        expect(out.isError, isTrue);
        expect(out.text, contains(stickerViewReadOnly));
      }
      expect(
        await store.index.fetch("SELECT 1 FROM ops WHERE run_id='script_run'"),
        isEmpty,
      );
    },
  );
  test(
    'tool names, descriptions and schemas exclude collisions and recursion',
    () async {
      AITool tool(String name) => AITool(
        name: name,
        description: 'desc $name',
        parameters: const {},
        inputSchema: const {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer'},
          },
        },
        handler: (_) async => 'ok',
      );
      final invocations = <String>[];
      final access = ScriptToolAccess(
        [
          tool('a:b'),
          tool('a-b'),
          tool('safe.tool'),
          tool('codemode'),
          tool('bash'),
        ],
        (name, args, active) async {
          invocations.add(name);
          return ToolOutput(text: 'done', structured: args);
        },
      );
      final out = await script(tools: access).run('''
text(tools.list().filter(t=>t.available).map(t=>t.exportName));
text(tools.describe("a_b").reason);
text(typeof tools.a_b);
text(tools.describe('safe_tool').parameters.properties.n.type);
text(await tools.safe_tool({n:42}));
''');
      expect(out.isError, isFalse, reason: out.text);
      expect(invocations, ['safe.tool']);
      expect(out.text, contains('["safe_tool","bash"]'));
      expect(out.text, contains('integer'));
      expect(out.text, contains('name collision'));
      expect(out.text, contains('undefined'));
      expect(out.text, isNot(contains('codemode')));
    },
  );
  test('image uses the H1 typed image channel', () async {
    final png = img.encodePng(img.Image(width: 2, height: 3));
    final out = await script().run(
      "await image('${base64Encode(png)}'); text('picture');",
    );
    expect(out.isError, isFalse, reason: out.text);
    expect(out.text, 'picture');
    expect(out.images.single.width, 2);
    expect(out.images.single.height, 3);
  });
  test(
    'console/text notifications retain all calls, including unawaited output',
    () async {
      final out = await script().run(
        'for(let i=0;i<100;i++) console.log(i); text("last");',
      );
      expect(out.isError, isFalse, reason: out.text);
      expect(out.text.split('\n'), hasLength(101));
      expect(out.text, endsWith('last'));
    },
  );
  for (final cancel in [false, true]) {
    test(
      'unawaited in-flight and queued writes cannot commit after timeout/cancel $cancel',
      () async {
        final gate = Completer<void>();
        var pending = 0, cancelled = false;
        store.afterIntent = (_) async {
          pending++;
          await gate.future;
        };
        final host = script(cancelled: () => cancelled);
        final future = host.run('''
for(let i=0;i<5;i++) ws.writeBytes('late'+i,new Uint8Array([1]));
await new Promise(()=>{});
''', timeout: const Duration(milliseconds: 200));
        await _until(() => pending > 0);
        if (cancel) cancelled = true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        gate.complete();
        final out = await future;
        expect(out.isError, isTrue);
        expect(
          (await store.files(ws)).where((f) => f.path.startsWith('late')),
          isEmpty,
        );
        expect(await store.index.fetch("SELECT 1 FROM claims"), isEmpty);
      },
    );
  }
  test(
    'Promise.all failure keeps completed writes but aborts and settles pending writes',
    () async {
      final gate = Completer<void>();
      var pending = false;
      store.afterIntent = (op) async {
        if (op.path == 'pending') {
          pending = true;
          await gate.future;
        }
      };
      final fail = AITool(
        name: 'fail',
        description: 'fail',
        parameters: const {},
        handler: (_) async => '',
      );
      final access = ScriptToolAccess([fail], (_, _, _) async {
        await _until(() => pending);
        throw StateError('expected failure');
      });
      final future = script(tools: access).run(
        "await ws.writeBytes('done',new Uint8Array([1])); await Promise.all([ws.writeBytes('pending',new Uint8Array([2])),tools.fail()]);",
      );
      await _until(() => pending);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      final out = await future;
      expect(out.isError, isTrue);
      expect(out.text, contains('expected failure'));
      expect((await store.read(ws, 'done')).$1, [1]);
      expect(await store.stat(ws, 'pending'), isNull);
      expect((await store.undoRun(ws, 'script_run')).undone, 1);
    },
  );
  test('synchronous exception cannot leave a late unawaited write', () async {
    final out = await script().run(
      "ws.writeBytes('late',new Uint8Array([1]));throw Error('boom');",
    );
    expect(out.isError, isTrue);
    expect(await store.stat(ws, 'late'), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await store.stat(ws, 'late'), isNull);
  });
  test(
    'truncated output artifact is host-owned, indexed and readable',
    () async {
      final out = await script().run('text("x".repeat(50*1024));');
      expect(out.isError, isFalse, reason: out.text);
      expect(out.text, contains('Output truncated;'));
      final path = (await store.files(
        ws,
      )).singleWhere((f) => f.path.startsWith('.aicove/outputs/')).path;
      expect((await store.read(ws, path)).$1.length, 50 * 1024 + 1);
      expect((await store.undoRun(ws, 'script_run')).undone, 0);
    },
  );
  test(
    'binary and long-line hints advertise run_js only where it is assembled',
    () async {
      await store.write(
        ws,
        'binary',
        Uint8List.fromList([0, 255, 0]),
        runId: 'setup',
      );
      await store.write(
        ws,
        'line',
        utf8.encode('x' * (50 * 1024 + 1)),
        runId: 'setup',
      );
      for (final enabled in [false, true]) {
        final read = WorkspaceToolset(
          store: store,
          workspaceIds: {ws},
          runId: 'r',
          enableScripts: enabled,
        ).tools().firstWhere((t) => t.name == 'read');
        for (final path in ['binary', 'line']) {
          expect(
            (await read.invoke({
              'workspace': ws,
              'path': path,
            })).text.contains('codemode'),
            enabled,
          );
        }
      }
    },
  );
  for (final n in [1999, 2000, 2001]) {
    test('model output line boundary $n', () {
      final buffer = WorkspaceScriptOutput();
      for (var i = 0; i < n; i++) {
        buffer.add('$i');
      }
      expect(
        buffer.modelText.trimRight().split('\n'),
        hasLength(n.clamp(0, 2000)),
      );
      expect(buffer.truncated, n > 2000);
      if (n > 2000) expect(buffer.modelText, startsWith('1\n'));
    });
  }
  for (final n in [50 * 1024 - 1, 50 * 1024, 50 * 1024 + 1]) {
    test('model output byte boundary $n', () {
      final buffer = WorkspaceScriptOutput()..add('x' * (n - 1));
      expect(utf8.encode(buffer.modelText).length, n.clamp(0, 50 * 1024));
      expect(buffer.truncated, n > 50 * 1024);
    });
  }
  for (final n in [8 * 1024 * 1024 - 1, 8 * 1024 * 1024, 8 * 1024 * 1024 + 1]) {
    test('full output byte boundary $n', () {
      final buffer = WorkspaceScriptOutput()..add('x' * (n - 1));
      expect(buffer.fileBytes.length, n.clamp(0, 8 * 1024 * 1024));
      expect(buffer.fileTruncated, n > 8 * 1024 * 1024);
    });
  }
  test('UTF8 tail remains decodable when truncation cuts a codepoint', () {
    final buffer = WorkspaceScriptOutput()
      ..add('猫' * (8 * 1024 * 1024 ~/ 3 + 10));
    expect(() => utf8.decode(buffer.fileBytes), returnsNormally);
    expect(utf8.encode(buffer.modelText).length, lessThanOrEqualTo(50 * 1024));
  });
  test(
    'script timeout aborts a real pending HTTP response and settles before returning',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>(), release = Completer<void>();
      server.listen((request) async {
        if (!received.isCompleted) received.complete();
        await release.future;
        try {
          request.response.write('late');
          await request.response.close();
        } catch (_) {}
      });
      try {
        final out =
            await script(
              network: () => PublicNetwork(
                resolve: (_) async => [InternetAddress('8.8.8.8')],
                connect: (_, _) => Socket.startConnect(
                  InternetAddress.loopbackIPv4,
                  server.port,
                ),
              ),
            ).run(
              "await fetch('http://public.example:${server.port}/'); await ws.writeBytes('late',new Uint8Array([1]));",
              timeout: const Duration(milliseconds: 200),
            );
        expect(received.isCompleted, isTrue);
        expect(out.isError, isTrue);
        expect(await store.stat(ws, 'late'), isNull);
      } finally {
        release.complete();
        await server.close(force: true);
      }
    },
  );
  test(
    'actual output beyond eight MiB persists only the final bounded tail',
    () async {
      final out = await script().run('text("x".repeat(8*1024*1024+64));');
      expect(out.isError, isFalse, reason: out.text);
      expect(out.text, contains('only the last 8 MiB retained'));
      final file = (await store.files(
        ws,
      )).singleWhere((f) => f.path.startsWith('.aicove/outputs/'));
      expect(file.size, 8 * 1024 * 1024);
      expect((await store.read(ws, file.path)).$1.length, 8 * 1024 * 1024);
    },
  );

  test(
    'typed failed child result rejects and can be handled with try/catch',
    () async {
      final child = AITool(
        name: 'fail',
        description: 'failure',
        parameters: const {},
        handler: (_) async => '',
      );
      final access = ScriptToolAccess(
        [child],
        (_, _, _) async =>
            const ToolOutput(text: 'child failed', isError: true),
      );
      final failed = await script(tools: access).run('await tools.fail();');
      expect(failed.isError, isTrue);
      expect(failed.text, contains('child failed'));
      final handled = await script(
        tools: access,
      ).run('try {await tools.fail();} catch(e) {text("handled");}');
      expect(handled.isError, isFalse, reason: handled.text);
      expect(handled.text, 'handled');
    },
  );
  test('base64 bytes copy and no Node, process or timers are exposed', () async {
    final out = await script().run(
      "await ws.writeBytes('a','AQID'); await ws.writeBytes('b',await ws.readBytes('a')); text([typeof process,typeof require,typeof setTimeout]);",
    );
    expect(out.isError, isFalse, reason: out.text);
    expect((await store.read(ws, 'b')).$1, [1, 2, 3]);
    expect(out.text, '["undefined","undefined","undefined"]');
  });
  test('empty lines do not manufacture truncation or artifacts', () {
    final buffer = WorkspaceScriptOutput()..add('');
    expect(buffer.modelText, '\n');
    expect(buffer.truncated, isFalse);
  });
  test('codemode schema preserves the code-only contract across providers', () {
    final run = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'r',
      enableScripts: true,
    ).tools().firstWhere((t) => t.name == 'codemode');
    final read = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'r',
    ).tools().firstWhere((t) => t.name == 'read');
    expect(run.toAnthropicSchema()['input_schema'], run.inputSchema);
    final body = GeminiAdapter().buildRequestBody(
      model: 'gemini-test',
      messages: const [],
      tools: [run.toOpenAISchema(), read.toOpenAISchema()],
    );
    final declarations =
        (body['tools'] as List).single['functionDeclarations'] as List;
    expect(declarations[0]['parameters'] ?? declarations[0]['parametersJsonSchema'], run.inputSchema);
    expect(
      declarations[1]['parameters'],
      read.toOpenAISchema()['function']['parameters'],
    );
    expect(declarations[1].containsKey('parametersJsonSchema'), isFalse);
  });
  test('returning text does not append a notification count', () async {
    final out = await script().run('return text(42);');
    expect(out.isError, isFalse, reason: out.text);
    expect(out.text, '42');
  });

  test(
    'final model text includes footer/errors inside the 50 KiB and 2000-line budgets',
    () async {
      for (final code in [
        'text("x".repeat(51201));',
        'for(let i=0;i<2001;i++)text(i);',
        'throw Error("e".repeat(51201));',
      ]) {
        final out = await script().run(code);
        expect(utf8.encode(out.text).length, lessThanOrEqualTo(50 * 1024));
        expect(out.text.split('\n').length, lessThanOrEqualTo(2000));
        expect(out.text, contains('full output: .aicove/outputs/'));
        expect(out.isError, code.startsWith('throw'));
      }
    },
  );
}
