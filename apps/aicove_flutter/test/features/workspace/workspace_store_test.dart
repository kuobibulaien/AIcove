import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_errors.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_models.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Crash implements Exception {}

void _writeEntry(List<Object> args) async {
  final reply = args[0] as SendPort;
  reply.send(await _writeElsewhere(args[1] as String, args[2] as String));
}

/// Runs in another isolate with its own index connection.
Future<String> _writeElsewhere(String rootPath, String ws) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final store = await WorkspaceStore.open(Directory(rootPath));
  try {
    await store.write(ws, 'N.TXT', utf8.encode('theirs'), runId: 'x');
    return 'written';
  } on WorkspaceException catch (e) {
    return e.code;
  } finally {
    await store.close();
  }
}

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();

Matcher _code(String code) =>
    isA<WorkspaceException>().having((e) => e.code, 'code', code);

void main() {
  late Directory root;
  final opened = <WorkspaceStore>[];

  Future<WorkspaceStore> open({
    Duration staleAfter = const Duration(seconds: 30),
    int quotaBytes = WorkspaceLimits.quotaBytes,
    int historyBytes = WorkspaceLimits.historyBytes,
  }) async {
    final store = await WorkspaceStore.open(
      root,
      staleAfter: staleAfter,
      quotaBytes: quotaBytes,
      historyBytes: historyBytes,
    );
    opened.add(store);
    return store;
  }

  Future<String> text(WorkspaceStore store, String ws, String path) async =>
      utf8.decode((await store.read(ws, path)).$1);

  Future<String> disk(WorkspaceStore store, String ws, String path) =>
      File(p.join(store.directoryOf(ws).path, path)).readAsString();

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace_store_test');
  });

  tearDown(() async {
    for (final store in opened) {
      await store.close();
    }
    opened.clear();
    await root.delete(recursive: true);
  });

  group('registry', () {
    test('ensureDefault registers the AIcove workspace once', () async {
      final store = await open();
      await store.ensureDefault();
      await store.ensureDefault();
      final all = await store.list();
      expect(all.single.id, defaultWorkspaceId);
      expect(all.single.name, 'AIcove');
    });

    test('create writes host metadata that tools cannot change', () async {
      final store = await open();
      final ws = await store.create(name: '笔记', description: '随手记');
      expect((await store.list()).single.name, '笔记');
      final meta = jsonDecode(
        await text(store, ws.id, '.aicove/workspace.json'),
      );
      expect(meta['id'], ws.id);
      await expectLater(
        store.write(ws.id, '.aicove/x.json', utf8.encode('{}'), runId: 'r'),
        throwsA(_code('read_only')),
      );
      expect(await store.runs(ws.id), isEmpty, reason: '宿主写入不进撤销列表');
    });
  });

  group('conditional commit', () {
    test('overwrite needs the current revision', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final first = await store.write(
        ws,
        'a.txt',
        utf8.encode('1'),
        runId: 'r',
      );
      expect(first.revision, _hash('1'));
      await expectLater(
        store.write(ws, 'a.txt', utf8.encode('2'), runId: 'r'),
        throwsA(_code('revision_mismatch')),
      );
      await expectLater(
        store.write(
          ws,
          'a.txt',
          utf8.encode('2'),
          expectedRevision: _hash('x'),
          runId: 'r',
        ),
        throwsA(_code('revision_mismatch')),
      );
      await store.write(
        ws,
        'a.txt',
        utf8.encode('2'),
        expectedRevision: first.revision,
        runId: 'r',
      );
      expect(await text(store, ws, 'a.txt'), '2');
    });

    test('two writers with one revision: only one commits', () async {
      final a = await open();
      final b = await open();
      final ws = (await a.create(name: 'w')).id;
      final base = await a.write(ws, 'f.md', utf8.encode('0'), runId: 'r0');
      final results = await Future.wait([
        for (final (store, value) in [(a, 'A'), (b, 'B')])
          store
              .write(
                ws,
                'f.md',
                utf8.encode(value),
                expectedRevision: base.revision,
                runId: 'r-$value',
              )
              .then((_) => value, onError: (Object e) => 'fail'),
      ]);
      expect(results.where((r) => r == 'fail'), hasLength(1));
      expect(await disk(a, ws, 'f.md'), results.firstWhere((r) => r != 'fail'));
    });

    test('a path occupied by an intent rejects another isolate', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final paused = Completer<void>();
      final release = Completer<void>();
      store.afterIntent = (_) async {
        paused.complete();
        await release.future;
      };
      final pending = store.write(ws, 'n.txt', utf8.encode('mine'), runId: 'r');
      await paused.future;
      final rootPath = root.path;
      final port = ReceivePort();
      await Isolate.spawn(_writeEntry, [port.sendPort, rootPath, ws]);
      final other = await port.first;
      expect(other, 'busy');
      release.complete();
      await pending;
      expect(await disk(store, ws, 'n.txt'), 'mine');
    });

    test('case duplicates and file/directory clashes are rejected', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      await store.write(ws, 'Doc/a.txt', utf8.encode('1'), runId: 'r');
      for (final path in ['doc/A.txt', 'Doc', 'Doc/a.txt/b']) {
        await expectLater(
          store.write(ws, path, utf8.encode('2'), runId: 'r'),
          throwsA(isA<WorkspaceException>()),
          reason: path,
        );
      }
    });

    test('file size limit: below, at and over', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      for (final (size, ok) in [
        (WorkspaceLimits.maxFileBytes - 1, true),
        (WorkspaceLimits.maxFileBytes, true),
        (WorkspaceLimits.maxFileBytes + 1, false),
      ]) {
        final write = store.write(
          ws,
          'big-$size',
          List.filled(size, 0),
          runId: 'r',
        );
        if (ok) {
          await write;
        } else {
          await expectLater(write, throwsA(_code('limit')));
        }
      }
    });

    test('quota: below, at and over', () async {
      final store = await open(quotaBytes: 1000);
      final ws = (await store.create(name: 'w')).id;
      final meta = (await store.stat(ws, '.aicove/workspace.json'))!.size;
      final room = 1000 - meta;
      await store.write(ws, 'a', List.filled(room - 1, 0), runId: 'r');
      await store.write(ws, 'b', [0], runId: 'r');
      await expectLater(
        store.write(ws, 'c', [0], runId: 'r'),
        throwsA(_code('limit')),
      );
    });

    test('a full history blocks writes that need it', () async {
      final store = await open(historyBytes: 3);
      final ws = (await store.create(name: 'w')).id;
      var file = await store.write(ws, 'a', utf8.encode('12'), runId: 'r');
      file = await store.write(
        ws,
        'a',
        utf8.encode('xyz'),
        expectedRevision: file.revision,
        runId: 'r',
      );
      await expectLater(
        store.write(
          ws,
          'a',
          utf8.encode('more'),
          expectedRevision: file.revision,
          runId: 'r',
        ),
        throwsA(_code('limit')),
      );
    });
  });

  group('recovery', () {
    test('crash after the intent: the change is voided', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final base = await store.write(ws, 'a', utf8.encode('old'), runId: 'r');
      store.afterIntent = (_) async => throw _Crash();
      await expectLater(
        store.write(
          ws,
          'a',
          utf8.encode('new'),
          expectedRevision: base.revision,
          runId: 'r',
        ),
        throwsA(isA<_Crash>()),
      );
      final fresh = await open();
      await expectLater(
        fresh.write(
          ws,
          'a',
          utf8.encode('again'),
          expectedRevision: base.revision,
          runId: 'r2',
        ),
        throwsA(_code('busy')),
        reason: '未过期的意图仍占着路径',
      );
      final later = await open(staleAfter: Duration.zero);
      expect(await disk(later, ws, 'a'), 'old');
      expect((await later.stat(ws, 'a'))!.revision, base.revision);
      await later.write(
        ws,
        'a',
        utf8.encode('again'),
        expectedRevision: base.revision,
        runId: 'r2',
      );
    });

    test('crash after the rename: the change is completed', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final base = await store.write(ws, 'a', utf8.encode('old'), runId: 'r');
      store.afterApply = (_) async => throw _Crash();
      await expectLater(
        store.write(
          ws,
          'a',
          utf8.encode('new'),
          expectedRevision: base.revision,
          runId: 'r',
        ),
        throwsA(isA<_Crash>()),
      );
      final later = await open(staleAfter: Duration.zero);
      expect((await later.stat(ws, 'a'))!.revision, _hash('new'));
      final result = await later.undoRun(ws, 'r');
      expect(result.conflicts, isEmpty);
      expect(await later.stat(ws, 'a'), isNull, reason: '恢复后的修改也能撤销');
    });

    test(
      'crash with foreign content on disk: the path is a conflict',
      () async {
        final store = await open();
        final ws = (await store.create(name: 'w')).id;
        final base = await store.write(ws, 'a', utf8.encode('old'), runId: 'r');
        store.afterIntent = (_) async => throw _Crash();
        await expectLater(
          store.write(
            ws,
            'a',
            utf8.encode('new'),
            expectedRevision: base.revision,
            runId: 'r2',
          ),
          throwsA(isA<_Crash>()),
        );
        await File(
          p.join(store.directoryOf(ws).path, 'a'),
        ).writeAsString('odd');
        final later = await open(staleAfter: Duration.zero);
        expect((await later.stat(ws, 'a'))!.revision, _hash('odd'));
        final result = await later.undoRun(ws, 'r');
        expect(result.conflicts, ['a'], reason: '冲突登记之后，更早的修改不再撤销');
        expect(await disk(later, ws, 'a'), 'odd');
      },
    );
  });

  group('undo', () {
    test('without later changes the workspace returns byte for byte', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final keep = await store.write(
        ws,
        'keep.txt',
        utf8.encode('k'),
        runId: 'r0',
      );
      final before = {
        for (final f in await store.files(ws)) f.path: f.revision,
      };
      var a = await store.write(ws, 'a.txt', utf8.encode('1'), runId: 'run');
      a = await store.write(
        ws,
        'a.txt',
        utf8.encode('2'),
        expectedRevision: a.revision,
        runId: 'run',
      );
      await store.write(
        ws,
        'keep.txt',
        utf8.encode('changed'),
        expectedRevision: keep.revision,
        runId: 'run',
      );
      await store.move(
        ws,
        'a.txt',
        'dir/b.txt',
        expectedRevision: a.revision,
        runId: 'run',
      );
      final moved = (await store.stat(ws, 'dir/b.txt'))!;
      await store.delete(
        ws,
        'dir/b.txt',
        expectedRevision: moved.revision,
        runId: 'run',
      );
      final result = await store.undoRun(ws, 'run');
      expect(result.conflicts, isEmpty);
      expect(result.undone, 5);
      expect({
        for (final f in await store.files(ws)) f.path: f.revision,
      }, before);
      expect(await disk(store, ws, 'keep.txt'), 'k');
      expect(
        Directory(p.join(store.directoryOf(ws).path, 'dir')).existsSync(),
        isFalse,
      );
      expect(
        (await store.runs(ws)).firstWhere((r) => r.runId == 'run').undone,
        isTrue,
      );
    });

    test('A writes 0→1→2, B writes 2→1: undoing A keeps B', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      var f = await store.write(ws, 'x', utf8.encode('0'), runId: 'r0');
      f = await store.write(
        ws,
        'x',
        utf8.encode('1'),
        expectedRevision: f.revision,
        runId: 'A',
      );
      f = await store.write(
        ws,
        'x',
        utf8.encode('2'),
        expectedRevision: f.revision,
        runId: 'A',
      );
      await store.write(
        ws,
        'x',
        utf8.encode('1'),
        expectedRevision: f.revision,
        runId: 'B',
      );
      final result = await store.undoRun(ws, 'A');
      expect(result.conflicts, ['x']);
      expect(result.undone, 0);
      expect(await disk(store, ws, 'x'), '1');
    });

    test(
      'a file deleted and recreated with the same content is not undone',
      () async {
        final store = await open();
        final ws = (await store.create(name: 'w')).id;
        final f = await store.write(ws, 'x', utf8.encode('same'), runId: 'A');
        await store.delete(ws, 'x', expectedRevision: f.revision, runId: 'B');
        await store.write(ws, 'x', utf8.encode('same'), runId: 'C');
        final result = await store.undoRun(ws, 'A');
        expect(result.conflicts, ['x']);
        expect(await disk(store, ws, 'x'), 'same');
      },
    );

    test('a later change to one path keeps only that path', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      final x = await store.write(ws, 'x', utf8.encode('1'), runId: 'A');
      await store.write(ws, 'y', utf8.encode('1'), runId: 'A');
      await store.write(
        ws,
        'x',
        utf8.encode('2'),
        expectedRevision: x.revision,
        runId: 'B',
      );
      final result = await store.undoRun(ws, 'A');
      expect(result.conflicts, ['x']);
      expect(await store.stat(ws, 'y'), isNull);
      expect(await disk(store, ws, 'x'), '2');
    });

    test('an undo interrupted by a crash continues', () async {
      final store = await open();
      final ws = (await store.create(name: 'w')).id;
      for (final name in ['a', 'b', 'c']) {
        await store.write(ws, name, utf8.encode(name), runId: 'A');
      }
      var calls = 0;
      store.afterApply = (op) async {
        if (op.undoes != null && ++calls == 2) throw _Crash();
      };
      await expectLater(store.undoRun(ws, 'A'), throwsA(isA<_Crash>()));
      final later = await open(staleAfter: Duration.zero);
      final result = await later.undoRun(ws, 'A');
      expect(result.conflicts, isEmpty);
      expect(result.undone, 3);
      expect(await later.files(ws), hasLength(1), reason: '只剩元数据');
    });
  });

  test('prune drops expired history and the content only it used', () async {
    var now = DateTime(2026, 1, 1);
    final store = await WorkspaceStore.open(root, clock: () => now);
    opened.add(store);
    final ws = (await store.create(name: 'w')).id;
    var f = await store.write(ws, 'a', utf8.encode('1'), runId: 'old');
    f = await store.write(
      ws,
      'a',
      utf8.encode('2'),
      expectedRevision: f.revision,
      runId: 'old',
    );
    final blobs = Directory(p.join(root.path, '.history', 'blobs'));
    expect(blobs.listSync(recursive: true).whereType<File>(), hasLength(1));
    now = now.add(const Duration(days: 31));
    await store.prune();
    expect(blobs.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(await store.runs(ws), isEmpty);
  });
}
