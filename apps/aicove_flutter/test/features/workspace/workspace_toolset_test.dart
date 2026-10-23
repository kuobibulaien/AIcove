import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/workspace/data/sticker_workspace_mount.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_read_only_mount.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_grants.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class _Mount implements WorkspaceReadOnlyMount {
  _Mount(this.content);
  final Map<String, Uint8List> content;
  @override
  Future<Map<String, MountedWorkspaceFile>> files() async => {
    for (final e in content.entries)
      e.key: MountedWorkspaceFile(
        size: e.value.length,
        revision: e.key,
        updatedAt: DateTime(2026),
        read: () async => e.value,
      ),
  };
}

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;
  late String other;
  late WorkspaceToolset toolset;

  Future<ToolOutput> call(String name, Map<String, dynamic> args) => toolset
      .tools()
      .firstWhere((t) => t.name == name)
      .invoke(args);
  Future<void> write(String content, {String path = 'a.txt'}) async {
    final out = await call('write', {
      'path': path,
      'content': content,
    });
    expect(out.isError, isFalse, reason: out.text);
  }

  Future<ToolOutput> read({String path = 'a.txt', int? offset, int? limit}) =>
      call('read', {
        'path': path,
        if (offset != null) 'offset': offset,
        if (limit != null) 'limit': limit,
      });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace_toolset_test');
    store = await WorkspaceStore.open(root);
    ws = (await store.create(name: '笔记', description: '随手记')).id;
    other = (await store.create(name: '别人的')).id;
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'run-1',
    );
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('prompt and authorization remain scoped', () async {
    expect(
      await toolset.prompt(),
      allOf(contains('笔记'), contains('随手记'), isNot(contains('别人的'))),
    );
    expect(
      (await call('workspace_open', {'id': other})).text,
      startsWith('unauthorized:'),
    );
  });
  test('workspace_run opens pages through AIcove and hands out the AI base',
      () async {
    expect(toolset.tools().map((t) => t.name), isNot(contains('workspace_run')));
    expect(await toolset.prompt(), isNot(contains('workspace_run')));
    final opened = <(String, String)>[];
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'run-1',
      runWebApp: (id, path) async {
        opened.add((id, path));
        return Uri.parse('http://$id.localhost:47823/$path');
      },
    );
    expect(await toolset.prompt(), contains('workspace_run'));
    final out = await call('workspace_run', {'path': 'game/index.html'});
    expect(out.isError, isFalse, reason: out.text);
    expect(opened, [(ws, 'game/index.html')]);
    expect(out.structured, {
      'url': 'http://$ws.localhost:47823/game/index.html',
      'ai_base_url': 'http://$ws.localhost:47823/__aicove/v1',
      'note': isA<String>(),
    });
    expect(
      ((await call('workspace_open', {'id': ws})).structured as Map)
          ['webapp_guide'],
      allOf(contains('workspace_run'), contains('ai_base_url')),
    );
  });
  test('plain text write/read/edit/move/delete and undo', () async {
    await write('hello world', path: 'notes/a.md');
    final original = await read(path: 'notes/a.md');
    expect(original.text, startsWith('hello world\nrevision: '));
    expect(original.text, isNot(startsWith('{')));
    expect(
      (await call('edit', {
        'path': 'notes/a.md',
        'old_text': 'world',
        'new_text': 'there',
        'expected_revision': 'stale',
      })).isError,
      isTrue,
    );
    final edit = await call('edit', {
      'path': 'notes/a.md',
      'old_text': 'world',
      'new_text': 'there',
    });
    expect(
      edit.text,
      allOf(
        contains('--- a/notes/a.md'),
        contains('-hello world'),
        contains('+hello there'),
        contains('first_changed_line: 1'),
      ),
    );
    expect((await call('workspace_list', {})).text, contains('notes/'));
    expect(
      (await call('workspace_move', {
        'from': 'notes/a.md',
        'to': 'moved.md',
      })).isError,
      isFalse,
    );
    expect(
      (await call('workspace_delete', {'path': 'moved.md'})).isError,
      isFalse,
    );
    final undone = await store.undoRun(ws, 'run-1');
    expect(undone.conflicts, isEmpty);
    expect(await store.stat(ws, 'notes/a.md'), isNull);
    expect(await store.stat(ws, 'moved.md'), isNull);
  });
  test(
    'overwrites need no revision, explicit stale revision still fails',
    () async {
      await write('one');
      await write('two');
      expect((await read()).text, startsWith('two\n'));
      expect(
        (await call('write', {
          'path': 'a.txt',
          'content': 'three',
          'expected_revision': 'stale',
        })).isError,
        isTrue,
      );
      expect((await read()).text, startsWith('two\n'));
    },
  );
  test('concurrent writers do not retry or silently overwrite', () async {
    await write('before');
    final entered = Completer<void>(), resume = Completer<void>();
    store.afterIntent = (_) async {
      entered.complete();
      await resume.future;
    };
    final first = call('write', {
      'path': 'a.txt',
      'content': 'first',
    });
    await entered.future;
    final second = await call('write', {
      'path': 'a.txt',
      'content': 'second',
    });
    expect(second.isError, isTrue);
    resume.complete();
    expect((await first).isError, isFalse);
    expect((await read()).text, startsWith('first\n'));
  });
  test(
    'multiple edits match the original file and preserve BOM/CRLF',
    () async {
      await store.write(ws, 'a.txt', [
        239,
        187,
        191,
        ...utf8.encode('first\r\nsecond\r\nthird\r\n'),
      ], runId: 'seed');
      final result = await call('edit', {
        'path': 'a.txt',
        'edits': [
          {'oldText': 'first\nsecond', 'newText': 'FIRST\nSECOND'},
          {'oldText': 'third', 'newText': 'THIRD'},
        ],
      });
      expect(result.isError, isFalse, reason: result.text);
      expect((await store.read(ws, 'a.txt')).$1, [
        239,
        187,
        191,
        ...utf8.encode('FIRST\r\nSECOND\r\nTHIRD\r\n'),
      ]);
    },
  );
  test(
    'ambiguous, missing, empty and overlapping edits are atomic failures',
    () async {
      await write('abc def abc');
      for (final edits in [
        [
          {'oldText': 'abc', 'newText': 'x'},
        ],
        [
          {'oldText': 'missing', 'newText': 'x'},
        ],
        [
          {'oldText': '', 'newText': 'x'},
        ],
        [
          {'oldText': 'abc def', 'newText': 'x'},
          {'oldText': 'def abc', 'newText': 'y'},
        ],
      ]) {
        expect(
          (await call('edit', {
            'path': 'a.txt',
            'edits': edits,
          })).isError,
          isTrue,
        );
        expect((await read()).text, startsWith('abc def abc\n'));
      }
      await write('aaa');
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'old_text': 'aa',
          'new_text': 'b',
        })).isError,
        isTrue,
        reason: 'overlapping duplicate matches are ambiguous',
      );
    },
  );
  for (final n in [
    WorkspaceLimits.maxWriteBytes - 1,
    WorkspaceLimits.maxWriteBytes,
    WorkspaceLimits.maxWriteBytes + 1,
  ]) {
    test('write and edited size boundary $n', () async {
      final result = await call('write', {
        'path': 'big',
        'content': 'x' * n,
      });
      expect(result.isError, n > WorkspaceLimits.maxWriteBytes);
      await write('start');
      final edited = await call('edit', {
        'path': 'a.txt',
        'old_text': 'start',
        'new_text': 'x' * n,
      });
      expect(edited.isError, n > WorkspaceLimits.maxWriteBytes);
    });
  }
  for (final n in [1999, 2000, 2001]) {
    test('read line count boundary $n', () async {
      await write(List.filled(n, 'x\n').join());
      final first = await read();
      expect(first.text.contains('内容已截断'), n > 2000);
      expect('x\n'.allMatches(first.text).length, n.clamp(0, 2000));
      if (n > 2000) {
        expect(first.text, contains('offset: 2001'));
        expect((await read(offset: 2001)).text, startsWith('x\n'));
      }
    });
  }
  for (final n in [50 * 1024 - 1, 50 * 1024, 50 * 1024 + 1]) {
    test('read byte boundary and overlong first line $n', () async {
      await write('a' * (n - 1) + '\n');
      final out = await read();
      expect(out.text.contains('单行超过'), n > 50 * 1024);
      if (n <= 50 * 1024) expect(out.text, startsWith('a' * (n - 1)));
      expect(out.text, isNot(contains('workspace_run_js')));
    });
  }
  test('read complete lines with multibyte UTF8, limit and offset', () async {
    await write('第一行\n第二行\n第三行');
    expect(
      (await read(offset: 2, limit: 1)).text,
      startsWith('第二行\n\nrevision:'),
    );
    expect((await read(offset: 2, limit: 1)).text, contains('offset: 3'));
    expect((await read(offset: 0)).isError, isTrue);
    expect((await read(limit: 0)).isError, isTrue);
    expect((await read(offset: 99)).text, startsWith('\nrevision:'));
  });
  for (final n in [499, 500, 501]) {
    test('grep Unicode line cap $n', () async {
      await write('猫' * n);
      final result = await call('workspace_grep', {'pattern': '猫'});
      expect(result.text, contains('猫' * (n > 500 ? 499 : n)));
      expect(result.text.contains('…'), n > 500);
    });
  }
  for (final n in [199, 200, 201]) {
    test('list glob grep result count boundary $n', () async {
      store.registerReadOnlyMount(
        ws,
        'view',
        _Mount({
          for (var i = 0; i < n; i++)
            '$i.txt': Uint8List.fromList(utf8.encode('needle')),
        }),
      );
      for (final (name, args) in [
        ('workspace_list', <String, dynamic>{'path': 'view'}),
        ('workspace_glob', <String, dynamic>{'pattern': 'view/*.txt'}),
        (
          'workspace_grep',
          <String, dynamic>{'pattern': 'needle', 'glob': 'view/*.txt'},
        ),
      ]) {
        final first = await call(name, args);
        expect(first.text.contains('truncated: true'), n > 200);
        if (n > 200) {
          expect(first.text, contains('next_cursor: 200'));
          final rest = await call(name, {...args, 'cursor': 200});
          expect(rest.text, isNot(contains('truncated: true')));
          expect(rest.text, contains('200.txt'));
        }
      }
    });
  }
  test('grep result byte cap below, at, above 64 KiB', () async {
    // 132 complete matches fit the count cap; the last line controls bytes.
    const count = 132;
    final prefixes = [for (var i = 1; i <= count; i++) 'a.txt:$i: '];
    final overhead = prefixes.fold<int>(
      0,
      (n, s) => n + utf8.encode(s).length + 1,
    );
    for (final size in [65535, 65536, 65537]) {
      var payload = size - overhead;
      final lines = <String>[];
      for (var i = 0; i < count; i++) {
        final chars = payload ~/ (count - i);
        lines.add('x' * chars);
        payload -= chars;
      }
      expect(payload, 0);
      await write(lines.join('\n'));
      final out = await call('workspace_grep', {
        'pattern': '.*',
        'glob': 'a.txt',
      });
      expect(out.text.contains('truncated: true'), size > 65536);
    }
  });
  for (final total in [199, 200, 201]) {
    test('unified diff line budget $total', () async {
      final original = List.generate(total - 4, (i) => 'old $i').join('\n');
      await write(original);
      final out = await call('edit', {
        'path': 'a.txt',
        'old_text': original,
        'new_text': 'new',
      });
      expect(out.isError, isFalse);
      expect(out.text.contains('(diff 已截断)'), total > 200);
      final diff = out.text
          .split('\n')
          .takeWhile(
            (s) =>
                !s.startsWith('first_changed_line:') && !s.startsWith('(diff'),
          )
          .toList();
      expect(diff.length, total.clamp(0, 200));
    });
  }
  test('binary result describes size and does not advertise H2', () async {
    await store.write(ws, 'raw.bin', [0, 255, 1], runId: 'seed');
    final result = await read(path: 'raw.bin');
    expect(
      result.text,
      allOf(
        contains('二进制'),
        contains('3 字节'),
        isNot(contains('workspace_run_js')),
      ),
    );
  });
  test(
    'read images and readonly view listed/globbed but not written',
    () async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 10, height: 10)),
      );
      store.registerReadOnlyMount(
        ws,
        'stickers',
        _Mount({
          'set/id.png': bytes,
          'index.md': Uint8List.fromList(utf8.encode('set id 开心')),
        }),
      );
      final image = await read(path: 'stickers/set/id.png');
      expect(image.images, hasLength(1));
      expect(image.images.single.source, '$ws/stickers/set/id.png');
      expect(
        (await read(path: 'stickers/index.md')).text,
        contains('set id 开心'),
      );
      expect((await call('workspace_list', {})).text, contains('stickers/'));
      expect(
        (await call('workspace_glob', {'pattern': 'stickers/**/*.png'})).text,
        contains('stickers/set/id.png'),
      );
      expect(
        (await call('workspace_grep', {
          'pattern': '.*',
          'glob': 'stickers/**/*.png',
        })).text,
        'matches: ',
      );
      await write('physical');
      for (final (name, args) in [
        (
          'write',
          <String, dynamic>{'path': 'stickers/new', 'content': 'x'},
        ),
        (
          'edit',
          <String, dynamic>{
            'path': 'stickers/index.md',
            'old_text': 'set',
            'new_text': 'x',
          },
        ),
        ('workspace_delete', <String, dynamic>{'path': 'stickers/index.md'}),
        (
          'workspace_move',
          <String, dynamic>{'from': 'stickers/index.md', 'to': 'out'},
        ),
        (
          'workspace_move',
          <String, dynamic>{'from': 'a.txt', 'to': 'stickers/new'},
        ),
      ]) {
        final denied = await call(name, args);
        expect(denied.isError, isTrue);
        expect(denied.text, stickerViewReadOnly);
      }
      expect((await read(path: 'stickers')).isError, isTrue);
    },
  );
  test(
    'sticker mount is a live view of the library without file copies',
    () async {
      final library = StickerLibrary(Directory('${root.path}/library'));
      await library.load();
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 2, height: 3)),
      );
      await library.importFiles([
        StickerImportFile('开心.png', bytes),
      ], packName: '测试套组');
      final pack = library.packs.single,
          sticker = library.packs.single.stickers.single;
      store.registerReadOnlyMount(
        ws,
        'stickers',
        StickerWorkspaceMount(() async => library),
      );
      final files = await store.files(ws);
      final path = files
          .singleWhere((f) => f.path.startsWith('stickers/${pack.id}/'))
          .path;
      expect((await store.read(ws, path)).$1, bytes);
      expect(await File('${store.directoryOf(ws).path}/$path').exists(), false);
      expect((await read(path: 'stickers/index.md')).text, contains('测试套组'));
      await library.updateSticker(sticker.id, tags: ['新标签']);
      expect((await read(path: 'stickers/index.md')).text, contains('新标签'));
      expect(
        (await call('write', {
          'path': 'Stickers/index.md',
          'content': 'bad',
        })).text,
        contains(stickerViewReadOnly),
      );
    },
  );
  test(
    'ancestor links, including workspace root, fail on reads and writes',
    () async {
      final outside = await Directory('${root.path}/outside').create();
      await File('${outside.path}/a').writeAsString('private');
      await Link('${store.directoryOf(ws).path}/linked').create(outside.path);
      expect((await read(path: 'linked/a')).isError, isTrue);
      expect(
        (await call('write', {
          'path': 'linked/new',
          'content': 'bad',
        })).isError,
        isTrue,
      );
      expect(await File('${outside.path}/new').exists(), isFalse);
      final actual = store.directoryOf(ws);
      final moved = '${actual.path}-moved';
      await actual.rename(moved);
      await Link(actual.path).create(moved);
      expect((await read(path: '.aicove/workspace.json')).isError, isTrue);
    },
  );
  test('cancelled run cannot commit and open/create preserve grants', () async {
    await write('先读 notes', path: 'AGENTS.md');
    final opened = await call('workspace_open', {'id':ws});
    expect(opened.text, allOf(contains('先读 notes'), contains('AGENTS.md')));
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'cancel',
      isCancelled: () => true,
    );
    expect(
      (await call('write', {'path': 'no', 'content': 'x'})).isError,
      isTrue,
    );
    final created = <String>[];
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {},
      runId: 'new',
      onCreated: (w) async => created.add(w.id),
    );
    final result = await call('workspace_create', {'name': '新的'});
    expect(result.isError, isFalse);
    expect(toolset.workspaceIds, created.toSet());
  });

  group('grants', () {
    test('stored grants keep unavailable IDs', () {
      expect(
        WorkspaceGrants.of([
          'tts',
          'workspace:a',
          'workspace:missing',
          'mcp:x',
        ]),
        {'a', 'missing'},
      );
      expect(WorkspaceGrants.of(null), isEmpty);
    });
    test('AIcove assistant owns default workspace', () {
      expect(WorkspaceGrants.forRole('aicove_assistant', null), {
        defaultWorkspaceId,
      });
      expect(WorkspaceGrants.forRole('aicove_assistant', ['workspace:a']), {
        'a',
        defaultWorkspaceId,
      });
      expect(WorkspaceGrants.forRole('nahida', null), isEmpty);
    });
    test('effective grants are intersection', () {
      expect(
        WorkspaceGrants.effective(
          roleGrants: {'a', 'b', 'missing'},
          presetAllows: {'a', 'c'},
          pluginEnabled: true,
          localIds: ['a', 'b', 'c'],
        ),
        {'a'},
      );
      expect(
        WorkspaceGrants.effective(
          roleGrants: {'a'},
          presetAllows: null,
          pluginEnabled: false,
          localIds: ['a'],
        ),
        isEmpty,
      );
    });
  });
}
