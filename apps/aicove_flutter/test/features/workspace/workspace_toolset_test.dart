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
import 'package:path/path.dart' as p;
import 'package:aicove_flutter/src/features/workspace/application/codemode_declarations.dart'
    show codemodeGuidance;

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

  Future<ToolOutput> call(String name, Map<String, dynamic> args) =>
      toolset.tools().firstWhere((t) => t.name == name).invoke(args);
  Future<void> write(String content, {String path = 'a.txt'}) async {
    final out = await call('write', {'path': path, 'content': content});
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

  Future<Directory> localDirectory() async {
    final directory = await Directory.systemTemp.createTemp('workspace_rules_');
    addTearDown(() => directory.delete(recursive: true));
    return directory;
  }

  void useLocal(Directory directory, {List<String> skillRoots = const []}) {
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'run-1',
      enableLocalFiles: true,
      currentLocalDirectory: directory.path,
      userSkillRoots: skillRoots,
    );
  }

  Future<void> localFile(
    Directory directory,
    String path,
    String content,
  ) async {
    final file = File(p.join(directory.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('workspace_search shares list, glob and grep behavior', () async {
    await write('needle\nother', path: 'notes/a.md');
    await write('needle', path: 'b.txt');
    for (final mode in ['list', 'glob', 'grep']) {
      final args = <String, dynamic>{
        if (mode != 'list') 'pattern': mode == 'glob' ? '**/*.md' : 'needle',
        if (mode == 'grep') 'glob': '**/*.md',
      };
      final atomic = await call('workspace_$mode', args);
      final aggregate = await call('workspace_search', {'mode': mode, ...args});
      expect(aggregate.isError, isFalse, reason: aggregate.text);
      expect(aggregate.text, atomic.text);
    }
    expect(
      (await call('workspace_search', {})).text,
      (await call('workspace_list', {})).text,
    );
    expect(
      (await call('workspace_search', {'pattern': '**/*.md'})).text,
      (await call('workspace_glob', {'pattern': '**/*.md'})).text,
    );
    expect((await call('workspace_search', {'mode': 'grep'})).isError, isTrue);
    expect(
      (await call('workspace_search', {'mode': 'invalid'})).isError,
      isTrue,
    );
  });

  test('without project rules the prompt is unchanged byte for byte', () async {
    expect(
      await toolset.prompt(),
      '$codemodeGuidance\n当前工作区：$ws。可用工作区：\n'
      '- 笔记（ID: $ws）：随手记\n路径都相对当前工作区。用 workspace_open({id}) 切换；workspace_create 新建后自动切换。',
    );
  });

  test('workspace tools declare complete structured output contracts', () {
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'schema',
      runWebApp: (_, _) async => Uri.parse('http://localhost:1234/index.html'),
    );
    const string = {'type': 'string'};
    const boolean = {'type': 'boolean'};
    const integer = {'type': 'integer'};
    const strings = {'type': 'array', 'items': string};
    const listing = {
      'truncated': boolean,
      'next_cursor': integer,
      'skipped_count': integer,
      'skipped': strings,
      'notice': string,
    };
    final schemas = <String, (Map<String, Object>, List<String>)>{
      'workspace_open': (
        {
          'directory': string,
          'name': string,
          'description': string,
          'agents_md': {
            'type': ['string', 'null'],
          },
          'instructions': string,
          'available_skills': string,
          'notice': string,
          'entries': strings,
          'skipped': strings,
          'webapp_guide': string,
        },
        ['entries', 'webapp_guide'],
      ),
      'workspace_run': (
        {'url': string, 'ai_base_url': string, 'note': string},
        ['url', 'ai_base_url', 'note'],
      ),
      'workspace_create': (
        {'workspace': string, 'name': string, 'notice': string},
        ['workspace', 'name'],
      ),
      'write': (
        {'path': string, 'revision': string, 'undoable': boolean},
        ['path', 'revision'],
      ),
      'workspace_list': ({'items': strings, ...listing}, ['items']),
      'workspace_glob': (
        {'items': strings, ...listing, 'scope': string},
        ['items'],
      ),
      'workspace_grep': (
        {'matches': strings, ...listing, 'scope': string},
        ['matches'],
      ),
      'workspace_move': ({'path': string, 'undoable': boolean}, ['path']),
      'workspace_delete': (
        {'deleted': boolean, 'undoable': boolean},
        ['deleted'],
      ),
    };
    for (final tool in toolset.tools()) {
      if (tool.name == 'workspace_search') {
        expect(tool.outputSchema, {
          'anyOf': [
            for (final name in [
              'workspace_list',
              'workspace_glob',
              'workspace_grep',
            ])
              {
                'type': 'object',
                'properties': schemas[name]!.$1,
                'required': schemas[name]!.$2,
              },
          ],
        });
        continue;
      }
      final expected = schemas[tool.name];
      expect(
        tool.outputSchema,
        expected == null
            ? null
            : {
                'type': 'object',
                'properties': expected.$1,
                'required': expected.$2,
              },
        reason: tool.name,
      );
    }
  });

  test('file descriptions distinguish image access and native undo limits', () {
    Map<String, String> descriptions() => {
      for (final tool in toolset.tools()) tool.name: tool.description,
    };
    expect(
      descriptions()['read'],
      '按行读取文本或查看图片；offset 从 1 开始，最多 2000 行或 50 KiB，返回续读行号与 revision（codemode 中读图仅返回 revision，看图请直接调用 read 或用 ws.readBytes）。',
    );
    expect(descriptions()['workspace_move'], '移动或重命名文件；目标不能已存在。');
    expect(descriptions()['workspace_delete'], '删除文件（可以撤销）。');
    toolset = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'local',
      enableLocalFiles: true,
      platform: 'macos',
    );
    expect(descriptions()['workspace_move'], '移动或重命名文件；目标不能已存在（本机目录改动不可撤销）。');
    expect(descriptions()['workspace_delete'], '删除文件（内部空间可撤销，本机目录直接删除且不可撤销）。');
  });

  test(
    'opening and creating workspaces retire previous project rules',
    () async {
      const notice = '当前工作区已切换，此前工作区的项目规则不再适用';
      final opened = await call('workspace_open', {'id': ws});
      expect((opened.structured as Map).containsKey('notice'), false);
      final created = await call('workspace_create', {'name': '新项目'});
      expect((created.structured as Map)['notice'], notice);
      final switched = await call('workspace_open', {'id': ws});
      expect((switched.structured as Map)['notice'], notice);
    },
  );

  test(
    'local platform context is explicit and never changes managed prompts',
    () async {
      final original = await toolset.prompt();
      toolset = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'platform',
        platform: 'windows',
      );
      expect(await toolset.prompt(), original);
      for (final platform in [null, 'macos', 'windows', 'linux']) {
        toolset = WorkspaceToolset(
          store: store,
          workspaceIds: {ws},
          runId: 'platform',
          enableLocalFiles: true,
          platform: platform,
        );
        final prompt = (await toolset.prompt())!;
        expect(prompt.contains('当前平台：'), platform != null);
        if (platform != null) expect(prompt, contains('当前平台：$platform。'));
        expect(prompt, isNot(contains(store.directoryOf(ws).path)));
        expect(prompt, isNot(contains('<available_skills>')));
      }
    },
  );

  test('managed rules and workspace_open share priority and fallback', () async {
    await write('claude instructions', path: 'CLAUDE.md');
    await write('agents instructions', path: 'AGENTS.md');
    await write('override instructions', path: 'AGENTS.override.md');
    expect(
      await toolset.prompt(),
      allOf(
        contains(
          'Project instructions (from workspace files; system and user instructions take precedence):',
        ),
        contains('--- AGENTS.override.md ---\noverride instructions'),
        isNot(contains('agents instructions')),
        isNot(contains('claude instructions')),
      ),
    );
    expect(
      ((await call('workspace_open', {'id': ws})).structured
          as Map)['agents_md'],
      'override instructions',
    );
    await write(' \n\t', path: 'AGENTS.override.md');
    expect(await toolset.prompt(), contains('agents instructions'));
    await store.write(
      ws,
      'AGENTS.md',
      [0xff],
      runId: 'seed',
      expectedRevision: (await store.read(ws, 'AGENTS.md')).$2,
    );
    expect(await toolset.prompt(), contains('claude instructions'));
    expect(
      ((await call('workspace_open', {'id': ws})).structured
          as Map)['agents_md'],
      'claude instructions',
    );
    await write('\x00binary', path: 'CLAUDE.md');
    expect(await toolset.prompt(), isNot(contains('Project instructions')));
    expect(
      ((await call('workspace_open', {'id': ws})).structured
          as Map)['agents_md'],
      isNull,
    );
  });

  test(
    'local rules ascend to git directory or git file and inject shallow first',
    () async {
      final project = await localDirectory();
      await localFile(project, 'AGENTS.md', 'outside repo');
      await localFile(project, 'repo/.git', 'gitdir: elsewhere');
      await localFile(project, 'repo/CLAUDE.md', 'repo rules');
      await localFile(project, 'repo/sub/AGENTS.override.md', 'sub rules');
      await localFile(project, 'repo/sub/AGENTS.md', 'lower priority');
      final sub = Directory(p.join(project.path, 'repo', 'sub'));
      useLocal(sub);
      final prompt = (await toolset.prompt())!;
      expect(
        prompt,
        allOf(
          contains('repo rules'),
          contains('sub rules'),
          isNot(contains('outside repo')),
          isNot(contains('lower priority')),
        ),
      );
      expect(
        prompt.indexOf('repo rules'),
        lessThan(prompt.indexOf('sub rules')),
      );
      final opened =
          (await call('workspace_open', {'path': sub.path})).structured as Map;
      expect(opened['agents_md'], 'sub rules');
      expect(
        opened['instructions'],
        allOf(
          startsWith('Project instructions'),
          contains('repo rules'),
          contains('sub rules'),
          isNot(contains('outside repo')),
        ),
      );
      expect(opened.containsKey('available_skills'), false);
      await File(p.join(project.path, 'repo', '.git')).delete();
      await Directory(p.join(project.path, 'repo', '.git')).create();
      expect(await toolset.prompt(), contains('repo rules'));
    },
  );

  test(
    'outside home without git only the current directory supplies rules',
    () async {
      final project = await localDirectory();
      await localFile(project, 'AGENTS.md', 'do not inherit');
      await localFile(project, 'sub/CLAUDE.md', 'current rules');
      useLocal(Directory(p.join(project.path, 'sub')));
      expect(
        await toolset.prompt(),
        allOf(contains('current rules'), isNot(contains('do not inherit'))),
      );
    },
  );

  test(
    'local directory aliases use the canonical ancestor chain',
    () async {
      final project = await localDirectory();
      await localFile(project, 'repo/.git', 'gitdir: elsewhere');
      await localFile(project, 'repo/AGENTS.md', 'canonical rules');
      final target = await Directory(
        p.join(project.path, 'repo', 'sub'),
      ).create();
      final alias = Link(p.join(project.path, 'alias'));
      await alias.create(target.path);
      useLocal(Directory(alias.path));
      expect(await toolset.prompt(), contains('canonical rules'));
    },
    skip: Platform.isWindows,
  );

  test(
    'unreadable and invalid local candidates do not prevent fallback',
    () async {
      final project = await localDirectory();
      await Directory(p.join(project.path, 'AGENTS.override.md')).create();
      await File(p.join(project.path, 'AGENTS.md')).writeAsBytes([0xff]);
      await localFile(project, 'CLAUDE.md', 'valid fallback');
      useLocal(project);
      expect(await toolset.prompt(), contains('valid fallback'));
      expect(
        ((await call('workspace_open', {'path': project.path})).structured
            as Map)['agents_md'],
        'valid fallback',
      );
    },
  );

  test('rules are cumulatively capped at 32 KiB on Unicode boundaries', () async {
    final project = await localDirectory();
    await localFile(project, '.git', 'gitdir: elsewhere');
    await localFile(project, 'AGENTS.md', 'top rules\n${'猫' * 5000}');
    await localFile(project, 'sub/AGENTS.md', 'bottom rules\n${'𠮷' * 10000}');
    final sub = Directory(p.join(project.path, 'sub'));
    useLocal(sub);
    final prompt = (await toolset.prompt())!;
    final section = prompt.substring(prompt.indexOf('\nProject instructions'));
    expect(utf8.encode(section).length, lessThanOrEqualTo(32 * 1024));
    expect(
      section,
      allOf(
        contains('top rules'),
        contains('bottom rules'),
        contains(
          '[已截断，完整内容请用 read 读取 ${p.join(await sub.resolveSymbolicLinks(), 'AGENTS.md')}]',
        ),
        isNot(contains('\ufffd')),
      ),
    );
    final guide =
        ((await call('workspace_open', {'path': sub.path})).structured
                as Map)['agents_md']
            as String;
    expect(utf8.encode(guide).length, lessThanOrEqualTo(32 * 1024));
    expect(guide, contains('[已截断，完整内容请用 read 读取'));
    // Managed workspaces use the same bounded reader.
    await call('workspace_open', {'id': ws});
    await write('猫' * 20000, path: 'AGENTS.md');
    final managed =
        ((await call('workspace_open', {'id': ws})).structured
                as Map)['agents_md']
            as String;
    expect(utf8.encode(managed).length, lessThanOrEqualTo(32 * 1024));
    expect(managed, endsWith('[已截断，完整内容请用 read 读取 AGENTS.md]'));
    final rulePath = RegExp(r'完整内容请用 read 读取 (.+)\]').firstMatch(managed)![1]!;
    expect((await read(path: rulePath)).isError, isFalse);
  });

  test(
    'cumulative truncation names the file whose body was actually cut',
    () async {
      final project = await localDirectory();
      await localFile(project, '.git', 'gitdir: elsewhere');
      await localFile(project, 'AGENTS.md', 'seed');
      final sub = await Directory(p.join(project.path, 'sub')).create();
      useLocal(sub);
      final before = (await toolset.prompt())!;
      final headerBytes =
          utf8
              .encode(
                before.substring(before.indexOf('\nProject instructions')),
              )
              .length -
          4;
      await localFile(
        project,
        'AGENTS.md',
        'x' * (32 * 1024 - 8 - headerBytes),
      );
      await localFile(
        project,
        'sub/AGENTS.md',
        'child rules exceed the remaining budget',
      );
      final prompt = (await toolset.prompt())!;
      final section = prompt.substring(
        prompt.indexOf('\nProject instructions'),
      );
      expect(utf8.encode(section).length, lessThanOrEqualTo(32 * 1024));
      expect(
        section,
        endsWith(
          '[已截断，完整内容请用 read 读取 ${p.join(await project.resolveSymbolicLinks(), 'AGENTS.md')}]',
        ),
      );
    },
  );

  test(
    'skills are local-only, project overrides user, and read loads the body',
    () async {
      final project = await localDirectory();
      final user = await localDirectory();
      await localFile(project, '.git', 'gitdir: elsewhere');
      await localFile(
        user,
        'common/SKILL.md',
        '---\nname: common\ndescription: user skill\n---\nuser body',
      );
      await localFile(
        project,
        '.agents/skills/common/SKILL.md',
        '---\nname: common\ndescription: project skill\n---\nprivate body',
      );
      await localFile(
        project,
        '.claude/skills/fallback/SKILL.md',
        '---\ndescription: >-\n  multi-line\n  description\n---\nbody',
      );
      toolset = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'run-1',
        enableLocalFiles: true,
        userSkillRoots: [user.path],
      );
      expect(await toolset.prompt(), isNot(contains('<available_skills>')));
      final opened =
          (await call('workspace_open', {'path': project.path})).structured
              as Map;
      expect(
        opened['available_skills'],
        allOf(
          startsWith('<available_skills>'),
          contains('- common: project skill ('),
          isNot(contains('private body')),
        ),
      );
      expect(opened.containsKey('instructions'), false);
      final prompt = (await toolset.prompt())!;
      expect(
        prompt,
        allOf(
          contains('- common: project skill ('),
          contains('- fallback: multi-line description ('),
          isNot(contains('user skill')),
          isNot(contains('private body')),
        ),
      );
      expect(
        (await read(
          path: p.join(project.path, '.agents/skills/common/SKILL.md'),
        )).text,
        contains('private body'),
      );
      await localFile(
        project,
        'sub/.claude/skills/common/SKILL.md',
        '---\nname: common\ndescription: deeper project skill\n---\n',
      );
      await call('workspace_open', {'path': p.join(project.path, 'sub')});
      expect(
        await toolset.prompt(),
        allOf(
          contains('- common: deeper project skill ('),
          contains('- fallback: multi-line description ('),
          isNot(contains('- common: project skill (')),
        ),
      );
      await call('workspace_open', {'id': ws});
      expect(await toolset.prompt(), isNot(contains('<available_skills>')));
    },
  );

  test(
    'skill parsing skips invalid, disabled, empty and overlong metadata',
    () async {
      final project = await localDirectory();
      await localFile(project, '.git', 'gitdir: elsewhere');
      const rootPath = '.agents/skills';
      for (final entry in {
        'disabled':
            '---\ndescription: hidden\ndisable-model-invocation: true\n---\n',
        'missing': '---\nname: missing\n---\n',
        'empty': '---\ndescription: " "\n---\n',
        'broken': '---\ndescription: [\n---\n',
        'late': '---\ndescription: ${'x' * 4096}\n---\n',
        'noheader': 'description: not frontmatter',
        'valid':
            '---\r\nname: valid\r\ndescription: "中文技能"\r\n---\r\n${'body' * 2000}',
      }.entries) {
        await localFile(
          project,
          '$rootPath/${entry.key}/SKILL.md',
          entry.value,
        );
      }
      await File(
        p.join(project.path, rootPath, 'valid', 'SKILL.md'),
      ).copy(p.join(project.path, 'SKILL.md'));
      useLocal(project);
      final prompt = (await toolset.prompt())!;
      final skills = prompt.substring(prompt.indexOf('<available_skills>'));
      expect(skills, contains('- valid: 中文技能 ('));
      expect(RegExp(r'^- ', multiLine: true).allMatches(skills), hasLength(1));
    },
  );

  test(
    'skill directory symlinks deduplicate by real SKILL.md path',
    () async {
      final project = await localDirectory();
      final user = await localDirectory();
      await localFile(project, '.git', 'gitdir: elsewhere');
      await localFile(
        user,
        'original/SKILL.md',
        '---\ndescription: shared skill\n---\n',
      );
      final skills = await Directory(
        p.join(project.path, '.agents', 'skills'),
      ).create(recursive: true);
      await Link(
        p.join(skills.path, 'alias'),
      ).create(p.join(user.path, 'original'));
      useLocal(project, skillRoots: [user.path]);
      final prompt = (await toolset.prompt())!;
      expect(prompt, contains('- original: shared skill ('));
      expect(prompt, isNot(contains('- alias:')));
      expect('shared skill'.allMatches(prompt), hasLength(1));
    },
    skip: Platform.isWindows,
  );

  test('skill discovery retains no more than 50 entries', () async {
    final project = await localDirectory();
    await localFile(project, '.git', 'gitdir: elsewhere');
    for (var i = 0; i < 52; i++) {
      await localFile(
        project,
        '.claude/skills/skill$i/SKILL.md',
        '---\ndescription: skill $i\n---\n',
      );
    }
    useLocal(project);
    final prompt = (await toolset.prompt())!;
    final skills = prompt.substring(prompt.indexOf('<available_skills>'));
    expect(RegExp(r'^- ', multiLine: true).allMatches(skills), hasLength(50));
  });

  test(
    'edit exact matches win over fuzzy alternatives and report counts',
    () async {
      await write('“hello” and "hello"');
      final result = await call('edit', {
        'path': 'a.txt',
        'old_text': '"hello"',
        'new_text': 'exact',
      });
      expect(result.isError, isFalse, reason: result.text);
      expect((await read()).text, startsWith('“hello” and exact\n'));
      await write('abc abc');
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'old_text': 'abc',
          'new_text': 'x',
        })).text,
        'ambiguous: oldText 必须在文件里唯一（匹配到 2 处）',
      );
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'old_text': 'missing',
          'new_text': 'x',
        })).text,
        'not_found: 在文件里找不到 oldText，请先 read 确认最新内容',
      );
    },
  );

  test(
    'fuzzy edit maps Unicode and trailing whitespace back to original CRLF',
    () async {
      const source =
          'prefix𠮷\r\n  ‘one’\u00a0—\t \r\n“two”\u3000\r\nsuffix\r\n';
      await store.write(ws, 'a.txt', [
        239,
        187,
        191,
        ...utf8.encode(source),
      ], runId: 'seed');
      final result = await call('edit', {
        'path': 'a.txt',
        'old_text': "'one' -\n\"two\"\n",
        'new_text': 'replacement\n',
      });
      expect(result.isError, isFalse, reason: result.text);
      expect((await store.read(ws, 'a.txt')).$1, [
        239,
        187,
        191,
        ...utf8.encode('prefix𠮷\r\n  replacement\r\nsuffix\r\n'),
      ]);
      await write('“tail”\u3000');
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'old_text': '"tail"',
          'new_text': 'done',
        })).isError,
        isFalse,
      );
      expect((await read()).text, startsWith('done\u3000\n'));
    },
  );

  test(
    'fuzzy edit supports every specified single-code-unit substitution',
    () async {
      final pairs = <(String, String)>[
        for (final char in '‘’‚‛'.split('')) (char, "'"),
        for (final char in '“”„‟'.split('')) (char, '"'),
        for (final char in '‐‑‒–—―−'.split('')) (char, '-'),
        for (final char
            in '\u00A0\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000'
                .split(''))
          (char, ' '),
      ];
      await write(
        [
          for (var i = 0; i < pairs.length; i++) 'row$i:${pairs[i].$1}end',
        ].join('\n'),
      );
      final output = await call('edit', {
        'path': 'a.txt',
        'edits': [
          for (var i = 0; i < pairs.length; i++)
            {'oldText': 'row$i:${pairs[i].$2}end', 'newText': 'done$i'},
        ],
      });
      expect(output.isError, isFalse, reason: output.text);
      expect(
        (await read()).text,
        startsWith(
          [for (var i = 0; i < pairs.length; i++) 'done$i'].join('\n'),
        ),
      );
    },
  );

  test(
    'fuzzy edit rejects ambiguity, empty normalization and NFKC changes',
    () async {
      await write('“same”\n„same‟');
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'old_text': '"same"',
          'new_text': 'x',
        })).text,
        'ambiguous: oldText 必须在文件里唯一（宽松匹配到 2 处）',
      );
      for (final sourceAndOld in [('中文，Ａ', '中文,A'), ('nothing', ' \t')]) {
        await write(sourceAndOld.$1);
        expect(
          (await call('edit', {
            'path': 'a.txt',
            'old_text': sourceAndOld.$2,
            'new_text': 'x',
          })).text,
          'not_found: 在文件里找不到 oldText，请先 read 确认最新内容',
        );
        expect((await read()).text, startsWith(sourceAndOld.$1));
      }
      await write('“abc”\nxyz');
      expect(
        (await call('edit', {
          'path': 'a.txt',
          'edits': [
            {'oldText': '"abc"\nxy', 'newText': 'first'},
            {'oldText': 'xyz', 'newText': 'second'},
          ],
        })).text,
        startsWith('overlap:'),
      );
      expect((await read()).text, startsWith('“abc”\nxyz'));
    },
  );

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
  test(
    'workspace_run opens pages through AIcove and hands out the AI base',
    () async {
      expect(
        toolset.tools().map((t) => t.name),
        isNot(contains('workspace_run')),
      );
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
        ((await call('workspace_open', {'id': ws})).structured
            as Map)['webapp_guide'],
        allOf(contains('workspace_run'), contains('ai_base_url')),
      );
    },
  );
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
    final first = call('write', {'path': 'a.txt', 'content': 'first'});
    await entered.future;
    final second = await call('write', {'path': 'a.txt', 'content': 'second'});
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
          (await call('edit', {'path': 'a.txt', 'edits': edits})).isError,
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
      final result = await call('write', {'path': 'big', 'content': 'x' * n});
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
        ('write', <String, dynamic>{'path': 'stickers/new', 'content': 'x'}),
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
        (await call('write', {'path': 'linked/new', 'content': 'bad'})).isError,
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
    final opened = await call('workspace_open', {'id': ws});
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
