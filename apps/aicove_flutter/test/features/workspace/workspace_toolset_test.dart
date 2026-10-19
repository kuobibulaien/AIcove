import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_grants.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;
  late String other;
  late WorkspaceToolset toolset;

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> args,
  ) async {
    final tool = toolset.tools().firstWhere((AITool t) => t.name == name);
    return jsonDecode((await tool.handler(args))!) as Map<String, dynamic>;
  }

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

  test('prompt lists only granted workspaces', () async {
    final prompt = await toolset.prompt();
    expect(prompt, contains('笔记'));
    expect(prompt, contains('随手记'));
    expect(prompt, isNot(contains('别人的')));
  });

  test('ungranted workspaces fail', () async {
    final result = await call('workspace_read', {
      'workspace': other,
      'path': 'a',
    });
    expect(result['error'], 'unauthorized');
  });

  test('write, read, edit and the run can be undone', () async {
    final written = await call('workspace_write', {
      'workspace': ws,
      'path': 'notes/a.md',
      'content': 'hello world',
    });
    expect(written['revision'], isNotEmpty);
    final read = await call('workspace_read', {
      'workspace': ws,
      'path': 'notes/a.md',
    });
    expect(read['content'], 'hello world');
    final stale = await call('workspace_edit', {
      'workspace': ws,
      'path': 'notes/a.md',
      'old_text': 'world',
      'new_text': 'there',
      'expected_revision': 'stale',
    });
    expect(stale['error'], 'revision_mismatch');
    final edited = await call('workspace_edit', {
      'workspace': ws,
      'path': 'notes/a.md',
      'old_text': 'world',
      'new_text': 'there',
      'expected_revision': read['revision'],
    });
    expect(edited['replaced'], 1);
    final listed = await call('workspace_list', {'workspace': ws});
    expect(listed['items'], containsAll(['.aicove/', 'notes/']));
    final result = await store.undoRun(ws, 'run-1');
    expect(result.conflicts, isEmpty);
    expect(await store.stat(ws, 'notes/a.md'), isNull);
  });

  test('edit needs a unique match unless replace_all', () async {
    final w = await call('workspace_write', {
      'workspace': ws,
      'path': 'x',
      'content': 'a a',
    });
    final ambiguous = await call('workspace_edit', {
      'workspace': ws,
      'path': 'x',
      'old_text': 'a',
      'new_text': 'b',
      'expected_revision': w['revision'],
    });
    expect(ambiguous['error'], 'ambiguous');
    final all = await call('workspace_edit', {
      'workspace': ws,
      'path': 'x',
      'old_text': 'a',
      'new_text': 'b',
      'expected_revision': w['revision'],
      'replace_all': true,
    });
    expect(all['replaced'], 2);
  });

  test('write size: below, at and over 1 MiB', () async {
    for (final (size, ok) in [
      (WorkspaceLimits.maxWriteBytes - 1, true),
      (WorkspaceLimits.maxWriteBytes, true),
      (WorkspaceLimits.maxWriteBytes + 1, false),
    ]) {
      final result = await call('workspace_write', {
        'workspace': ws,
        'path': 'big-$size.txt',
        'content': 'a' * size,
      });
      expect(result.containsKey('error'), !ok, reason: '$size');
    }
  });

  test('read pages at 64 KiB', () async {
    const size = WorkspaceLimits.maxReadBytes;
    for (final (length, paged) in [
      (size - 1, false),
      (size, false),
      (size + 1, true),
    ]) {
      await call('workspace_write', {
        'workspace': ws,
        'path': 'p$length',
        'content': 'b' * length,
      });
      final first = await call('workspace_read', {
        'workspace': ws,
        'path': 'p$length',
      });
      expect(first.containsKey('next_offset'), paged, reason: '$length');
      if (paged) {
        final rest = await call('workspace_read', {
          'workspace': ws,
          'path': 'p$length',
          'offset': first['next_offset'],
        });
        expect(
          (first['content'] as String).length +
              (rest['content'] as String).length,
          length,
        );
      }
    }
  });

  test('glob, grep and result paging', () async {
    for (var i = 0; i < 201; i++) {
      await call('workspace_write', {
        'workspace': ws,
        'path': 'many/f${i.toString().padLeft(3, '0')}.txt',
        'content': 'needle $i',
      });
    }
    await call('workspace_write', {
      'workspace': ws,
      'path': 'top.md',
      'content': 'needle',
    });
    final md = await call('workspace_glob', {
      'workspace': ws,
      'pattern': '**/*.md',
    });
    expect(md['items'], ['top.md']);
    final txt = await call('workspace_glob', {
      'workspace': ws,
      'pattern': 'many/*.txt',
    });
    expect(txt['items'], hasLength(200));
    expect(txt['next_cursor'], 200);
    final rest = await call('workspace_glob', {
      'workspace': ws,
      'pattern': 'many/*.txt',
      'cursor': txt['next_cursor'],
    });
    expect(rest['items'], hasLength(1));
    final hits = await call('workspace_grep', {
      'workspace': ws,
      'pattern': r'needle \d+$',
      'glob': 'many/**',
    });
    expect(hits['matches'], hasLength(200));
    expect(hits['truncated'], isTrue);
    final more = await call('workspace_grep', {
      'workspace': ws,
      'pattern': r'needle \d+$',
      'glob': 'many/**',
      'cursor': hits['next_cursor'],
    });
    expect(more['matches'], hasLength(1));
  });

  test('open returns AGENTS.md and the top level', () async {
    await call('workspace_write', {
      'workspace': ws,
      'path': 'AGENTS.md',
      'content': '先读 notes',
    });
    final opened = await call('workspace_open', {'workspace': ws});
    expect(opened['agents_md'], '先读 notes');
    expect(opened['entries'], contains('AGENTS.md'));
  });

  test('create grants the new workspace to the run', () async {
    final created = <String>[];
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {},
      runId: 'r',
      onCreated: (info) async => created.add(info.id),
    );
    final result = await call('workspace_create', {'name': '新的'});
    expect(created, [result['workspace']]);
    expect(toolset.workspaceIds, {result['workspace']});
  });

  group('grants', () {
    test('stored in the plugin list and kept when absent locally', () {
      final plugins = ['tts', 'workspace:a', 'workspace:missing', 'mcp:x'];
      expect(WorkspaceGrants.of(plugins), {'a', 'missing'});
      expect(WorkspaceGrants.of(null), isEmpty, reason: '「全部插件」不含工作区');
    });

    test('effective = role ∩ preset ∩ enabled ∩ local', () {
      Set<String> resolve({Set<String>? preset, bool enabled = true}) =>
          WorkspaceGrants.effective(
            roleGrants: {'a', 'b', 'missing'},
            presetAllows: preset,
            pluginEnabled: enabled,
            localIds: ['a', 'b', 'c'],
          );
      expect(resolve(), {'a', 'b'});
      expect(resolve(preset: {'a', 'c'}), {'a'}, reason: '预设不能扩大权限');
      expect(resolve(enabled: false), isEmpty);
    });
  });
}
