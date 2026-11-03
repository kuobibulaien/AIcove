import 'package:aicove_flutter/src/features/workspace/data/local_workspace_files.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_file_access.dart';
import 'package:aicove_flutter/src/features/workspace/data/gitignore_matcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/application/codemode_script.dart';

class _InterceptedToolset extends WorkspaceToolset {
  _InterceptedToolset({
    required super.store,
    required String directory,
    required this.beforeResolve,
  }) : super(
         workspaceIds: {'aicove'},
         runId: 'race-test',
         enableLocalFiles: true,
         currentLocalDirectory: directory,
       );

  final Future<void> Function(String) beforeResolve;

  @override
  Future<WorkspaceFileTarget> resolveFile(
    String input, {
    bool directory = false,
    bool rejectFallback = false,
  }) async {
    await beforeResolve(input);
    return super.resolveFile(
      input,
      directory: directory,
      rejectFallback: rejectFallback,
    );
  }
}

void main() {
  late Directory temp, project;
  late WorkspaceStore store;
  late WorkspaceToolset tools;
  Future<ToolOutput> call(String name, Map<String, dynamic> args) =>
      tools.tools().firstWhere((t) => t.name == name).invoke(args);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local-workspace-');
    project = await Directory('${temp.path}/project with 空格').create();
    store = await WorkspaceStore.open(Directory('${temp.path}/managed'));
    await store.ensureDefault();
    tools = WorkspaceToolset(
      store: store,
      workspaceIds: {'aicove'},
      runId: 'local-test',
      enableLocalFiles: true,
    );
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test('directory lost between checks never redirects a write', () async {
    final racing = _InterceptedToolset(
      store: store,
      directory: project.path,
      beforeResolve: (_) => project.delete(recursive: true),
    );
    final result = await racing
        .tools()
        .firstWhere((t) => t.name == 'write')
        .invoke({'path': 'race.txt', 'content': 'wrong target'});
    expect(result.isError, true);
    expect(result.text, contains('directory_unavailable'));
    expect(
      await File('${store.directoryOf('aicove').path}/race.txt').exists(),
      false,
    );
  });

  test('directory lost between checks adds notice to a read', () async {
    await File(
      '${store.directoryOf('aicove').path}/race.txt',
    ).writeAsString('default content');
    final racing = _InterceptedToolset(
      store: store,
      directory: project.path,
      beforeResolve: (_) => project.delete(recursive: true),
    );
    final result = await racing
        .tools()
        .firstWhere((t) => t.name == 'read')
        .invoke({'path': 'race.txt'});
    expect(result.isError, false, reason: result.text);
    expect(result.text, contains('default content'));
    expect(result.text, contains('已切回默认空间'));
  });

  test(
    'concurrent fallback cannot redirect an already started write',
    () async {
      final entered = Completer<void>();
      final resume = Completer<void>();
      final racing = _InterceptedToolset(
        store: store,
        directory: project.path,
        beforeResolve: (path) async {
          if (path == 'write.txt') {
            entered.complete();
            await resume.future;
          }
        },
      );
      final byName = {for (final tool in racing.tools()) tool.name: tool};
      final write = byName['write']!.invoke({
        'path': 'write.txt',
        'content': 'wrong target',
      });
      await entered.future;
      await project.delete(recursive: true);
      final listing = await byName['workspace_list']!.invoke({});
      expect(listing.isError, false, reason: listing.text);
      expect(listing.text, contains('已切回默认空间'));
      resume.complete();
      final result = await write;
      expect(result.isError, true);
      expect(result.text, contains('directory_unavailable'));
      expect(
        await File('${store.directoryOf('aicove').path}/write.txt').exists(),
        false,
      );
    },
  );

  test(
    'existing workspace_open accepts a directory; all file tools use disk',
    () async {
      expect(
        (await call('workspace_open', {'path': project.path})).isError,
        false,
      );
      expect(
        (await call('write', {
          'path': 'src/a.txt',
          'content': 'hello',
        })).isError,
        false,
      );
      expect(await File('${project.path}/src/a.txt').readAsString(), 'hello');
      expect(
        (await call('edit', {
          'path': 'src/a.txt',
          'old_text': 'hello',
          'new_text': 'world',
        })).isError,
        false,
      );
      expect(
        (await call('read', {'path': 'src/a.txt'})).text,
        contains('world'),
      );
      expect((await call('workspace_list', {})).text, contains('src/'));
      expect(
        (await call('workspace_glob', {'pattern': '**/*.txt'})).text,
        contains('src/a.txt'),
      );
      expect(
        (await call('workspace_grep', {'pattern': 'world'})).text,
        contains('src/a.txt:1: world'),
      );
      expect(await store.runs('aicove'), isEmpty);
      expect(tools.changed, isEmpty);
      expect(tools.tools().any((t) => t.name == 'directory_open'), false);
    },
  );

  test(
    'absolute paths work without switching; managed host protection survives aliases',
    () async {
      final path = '${project.path}/absolute.txt';
      expect(
        (await call('write', {'path': path, 'content': 'outside'})).isError,
        false,
      );
      expect((await call('read', {'path': path})).text, contains('outside'));
      final host = '${store.directoryOf('aicove').path}/.aicove/workspace.json';
      expect(
        (await call('write', {'path': host, 'content': 'bad'})).isError,
        true,
      );
      final alias = Link('${project.path}/alias');
      await alias.create(store.directoryOf('aicove').path);
      expect(
        (await call('write', {
          'path': '${alias.path}/.aicove/workspace.json',
          'content': 'bad',
        })).isError,
        true,
      );
      expect(
        (await call('write', {
          'path': '${store.root.path}/.index.sqlite',
          'content': 'bad',
        })).isError,
        true,
      );
    },
  );

  test('local edit and grep exceed 1 MiB, read exceeds 32 MiB', () async {
    await call('workspace_open', {'id': project.path});
    final content = '${'x\n' * (1 << 19)}needle\n';
    expect(
      (await call('write', {'path': 'large.txt', 'content': content})).isError,
      false,
    );
    expect(
      (await call('edit', {
        'path': 'large.txt',
        'old_text': 'needle',
        'new_text': 'found',
      })).isError,
      false,
    );
    expect(
      (await call('workspace_grep', {'pattern': 'found'})).text,
      contains('found'),
    );
    final big = File('${project.path}/huge.txt');
    final sink = big.openWrite();
    for (var i = 0; i < 34; i++) {
      sink.add(utf8.encode('a\n' * (1 << 19)));
    }
    await sink.close();
    final out = await call('read', {'path': 'huge.txt', 'limit': 2});
    expect(out.isError, false, reason: out.text);
    expect(out.text, contains('offset: 3'));
  });

  test(
    'missing remembered local directory falls back and explains it in prompt',
    () async {
      String? saved;
      tools = WorkspaceToolset(
        store: store,
        workspaceIds: {'aicove'},
        runId: 'restore',
        enableLocalFiles: true,
        currentLocalDirectory: '${temp.path}/gone',
        onLocalDirectoryChanged: (path) async {
          saved = path ?? 'managed';
        },
      );
      expect(
        await tools.prompt(),
        allOf(contains('已不可用'), contains('已切回默认空间')),
      );
      expect(saved, 'managed');
      expect(await tools.prompt(), contains('已切回默认空间'));
      expect(
        (await call('write', {
          'path': 'fallback.txt',
          'content': 'ok',
        })).isError,
        false,
      );
      expect(await store.stat('aicove', 'fallback.txt'), isNotNull);
    },
  );

  for (final operation in <String, Map<String, dynamic>>{
    'write': {'path': 'keep.txt', 'content': 'replaced'},
    'edit': {'path': 'keep.txt', 'old_text': 'keep', 'new_text': 'replaced'},
    'workspace_move': {'from': 'keep.txt', 'to': 'moved.txt'},
    'workspace_delete': {'path': 'keep.txt'},
  }.entries) {
    test(
      '${operation.key} rejects a local directory lost during the run',
      () async {
        await store.write(
          'aicove',
          'keep.txt',
          utf8.encode('keep'),
          runId: 'seed',
        );
        await call('workspace_open', {'path': project.path});
        await project.delete(recursive: true);
        final out = await call(operation.key, operation.value);
        expect(out.isError, true, reason: out.text);
        expect(out.text, startsWith('directory_unavailable:'));
        expect(out.text, contains('请重新确认目标空间或路径后再执行修改'));
        expect(
          utf8.decode((await store.read('aicove', 'keep.txt')).$1),
          'keep',
        );
        expect(await store.stat('aicove', 'moved.txt'), isNull);
        expect(tools.currentWorkspaceId, 'aicove');
        expect(await tools.prompt(), isNot(contains('已切回默认空间')));
      },
    );
  }

  for (final operation in <String, Map<String, dynamic>>{
    'read': {'path': 'keep.txt'},
    'workspace_list': {},
    'workspace_glob': {'pattern': '*.txt'},
    'workspace_grep': {'pattern': 'keep'},
  }.entries) {
    test(
      '${operation.key} reports fallback while reading the default workspace',
      () async {
        await store.write(
          'aicove',
          'keep.txt',
          utf8.encode('keep'),
          runId: 'seed',
        );
        await call('workspace_open', {'path': project.path});
        await project.delete(recursive: true);
        final out = await call(operation.key, operation.value);
        expect(out.isError, false, reason: out.text);
        expect(out.text, contains('已不可用，已切回默认空间'));
        expect(out.text, contains('keep'));
        if (operation.key != 'read') {
          expect((out.structured as Map)['notice'], contains('已不可用，已切回默认空间'));
        }
      },
    );
  }

  test(
    'a tool consumes its fallback notice before the following prompt',
    () async {
      await call('workspace_open', {'path': project.path});
      await project.delete(recursive: true);
      final out = await call('workspace_list', {});
      expect(out.isError, false, reason: out.text);
      expect((out.structured as Map)['notice'], contains('已切回默认空间'));
      expect(await tools.prompt(), isNot(contains('已切回默认空间')));
    },
  );

  test(
    'reopening the same local directory does not retire its rules',
    () async {
      final first = await call('workspace_open', {'path': project.path});
      expect((first.structured as Map)['notice'], '当前工作区已切换，此前工作区的项目规则不再适用');
      final again = await call('workspace_open', {'path': project.path});
      expect((again.structured as Map).containsKey('notice'), false);
    },
  );

  test(
    'fallback notices survive failed reads and explicit workspace switches',
    () async {
      await call('workspace_open', {'path': project.path});
      await project.delete(recursive: true);
      final read = await call('read', {'path': 'missing.txt'});
      expect(read.isError, true);
      expect(read.text, contains('notice: 上次的本机目录'));

      await project.create();
      await call('workspace_open', {'path': project.path});
      await project.delete(recursive: true);
      final created = await call('workspace_create', {'name': '新项目'});
      expect(created.isError, false, reason: created.text);
      expect(
        (created.structured as Map)['notice'],
        allOf(contains('已不可用，已切回默认空间'), endsWith('当前工作区已切换，此前工作区的项目规则不再适用')),
      );
    },
  );

  test('workspace_run can preview the fallback workspace', () async {
    final opened = <(String, String)>[];
    tools = WorkspaceToolset(
      store: store,
      workspaceIds: {'aicove'},
      runId: 'preview-fallback',
      enableLocalFiles: true,
      currentLocalDirectory: project.path,
      runWebApp: (workspace, path) async {
        opened.add((workspace, path));
        return Uri.parse('http://localhost:1234/$path');
      },
    );
    await project.delete(recursive: true);
    final out = await call('workspace_run', {'path': 'index.html'});
    expect(out.isError, false, reason: out.text);
    expect(opened, [('aicove', 'index.html')]);
    expect((out.structured as Map)['notice'], contains('已不可用，已切回默认空间'));
  });

  test('local capability is opt-in, and internal limits remain', () async {
    tools = WorkspaceToolset(
      store: store,
      workspaceIds: {'aicove'},
      runId: 'old',
    );
    expect(
      (await call('workspace_open', {'path': project.path})).isError,
      true,
    );
    expect(
      (await call('write', {
        'path': '${project.path}/no',
        'content': 'x',
      })).isError,
      true,
    );
    expect(
      (await call('write', {
        'path': 'too-big',
        'content': 'x' * ((1 << 20) + 1),
      })).isError,
      true,
    );
  });

  test(
    'relative and home directory opens persist locally and switch back by ID',
    () async {
      String? saved;
      tools = WorkspaceToolset(
        store: store,
        workspaceIds: {'aicove'},
        runId: 'paths',
        enableLocalFiles: true,
        onLocalDirectoryChanged: (v) async {
          saved = v;
        },
      );
      await call('workspace_open', {'id': project.path});
      await Directory('${project.path}/child').create();
      expect((await call('workspace_open', {'path': 'child'})).isError, false);
      expect(saved, '${await project.resolveSymbolicLinks()}/child');
      expect((await call('workspace_open', {'path': '..'})).isError, false);
      expect(saved, await project.resolveSymbolicLinks());
      await Directory('${project.path}/aicove').create();
      expect((await call('workspace_open', {'path': 'aicove'})).isError, false);
      expect(saved, '${await project.resolveSymbolicLinks()}/aicove');
      expect((await call('workspace_open', {'path': '~'})).isError, false);
      expect(
        saved,
        await Directory(Platform.environment['HOME']!).resolveSymbolicLinks(),
      );
      await call('workspace_open', {'id': 'aicove'});
      expect(saved, isNull);
      expect(tools.currentWorkspaceId, 'aicove');
      expect(
        (await call('workspace_open', {
          'id': 'aicove',
          'path': project.path,
        })).isError,
        true,
      );
    },
  );

  test(
    'native replacement preserves BOM, CRLF, executable mode and file link',
    () async {
      final target = File('${project.path}/real.txt');
      final original = [239, 187, 191, ...utf8.encode('one\r\ntwo\r\n')];
      await target.writeAsBytes(original);
      await Process.run('chmod', ['755', target.path]);
      final link = Link('${project.path}/linked.txt');
      await link.create(target.path);
      final result = await call('edit', {
        'path': link.path,
        'old_text': 'one\ntwo',
        'new_text': 'ONE\nTWO',
      });
      expect(result.isError, false, reason: result.text);
      expect(await target.readAsBytes(), [
        239,
        187,
        191,
        ...utf8.encode('ONE\r\nTWO\r\n'),
      ]);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect((await target.stat()).mode & 0x1ff, 0x1ed);
      expect(
        await project.list().map((e) => e.path).toList(),
        isNot(contains(contains('.aicove-write-'))),
      );
    },
  );

  test(
    'stale revisions, concurrent edits and cancellation do not overwrite',
    () async {
      final file = File('${project.path}/race.txt');
      await file.writeAsString('initial');
      final read = await call('read', {'path': file.path});
      final revision = RegExp(
        r'revision: (\w+)',
      ).firstMatch(read.text)!.group(1)!;
      final outputs = await Future.wait([
        call('write', {
          'path': file.path,
          'content': 'first',
          'expected_revision': revision,
        }),
        call('write', {
          'path': file.path,
          'content': 'second',
          'expected_revision': revision,
        }),
      ]);
      expect(outputs.where((o) => !o.isError).length, 1);
      final before = await file.readAsString();
      tools = WorkspaceToolset(
        store: store,
        workspaceIds: {'aicove'},
        runId: 'cancelled',
        enableLocalFiles: true,
        isCancelled: () => true,
      );
      expect(
        (await call('write', {'path': file.path, 'content': 'bad'})).isError,
        true,
      );
      expect(await file.readAsString(), before);
      expect(
        await project.list().any((e) => e.path.contains('.aicove-write-')),
        false,
      );
    },
  );

  test(
    'search supports explicit roots, ignored directories, and managed large text',
    () async {
      await File('${project.path}/a.txt').writeAsString('needle');
      await Directory('${project.path}/node_modules').create();
      await File('${project.path}/node_modules/b.txt').writeAsString('needle');
      final out = await call('workspace_grep', {
        'path': project.path,
        'pattern': 'needle',
      });
      expect(out.text, contains('a.txt:1: needle'));
      expect(out.text, isNot(contains('b.txt:1:')));
      expect(out.text, isNot(contains('skipped_count:')));
      expect(
        (await call('workspace_glob', {
          'path': project.path,
          'pattern': '**/*.txt',
          'include_ignored': true,
        })).text,
        contains('node_modules/b.txt'),
      );
      await store.write(
        'aicove',
        'big.txt',
        utf8.encode('${'x\n' * (1 << 19)}managed-needle\n'),
        runId: 'host',
      );
      expect(
        (await call('workspace_grep', {'pattern': 'managed-needle'})).text,
        contains('managed-needle'),
      );
    },
  );

  test('gitignore wildcards, anchors, escapes and ordered negation', () {
    final matcher = GitignoreMatcher().withRules(
      r'''
# comment
*.log
!keep.log
/root.txt
cache/
file?.[ch]
data/[!a-c].txt
**/secret.txt
docs/**/draft.md
generated/**
\#literal
\!literal
invalid[z-a]
literal[]a].txt
'''
      r'space\ '
      '\n',
      base: '',
    );
    bool ignores(String path, {bool directory = false}) =>
        matcher.ignores(path, isDirectory: directory);
    for (final path in [
      'a.log',
      'nested/a.log',
      'root.txt',
      'file1.c',
      'src/file2.h',
      'data/z.txt',
      'secret.txt',
      'a/b/secret.txt',
      'docs/draft.md',
      'docs/a/b/draft.md',
      'generated/a/b.txt',
      '#literal',
      '!literal',
      'space ',
      'literal].txt',
    ]) {
      expect(ignores(path), true, reason: path);
    }
    for (final path in [
      'keep.log',
      'nested/keep.log',
      'nested/root.txt',
      'cache',
      'file12.c',
      'data/a.txt',
      'other/draft.md',
      'generated',
      'comment',
    ]) {
      expect(ignores(path), false, reason: path);
    }
    expect(ignores('nested/cache', directory: true), true);
    final nested = matcher.withRules('!a.log\n/local.txt\n', base: 'src');
    expect(nested.ignores('src/a.log', isDirectory: false), false);
    expect(nested.ignores('other/a.log', isDirectory: false), true);
    expect(nested.ignores('src/local.txt', isDirectory: false), true);
    expect(nested.ignores('src/deep/local.txt', isDirectory: false), false);
  });

  test(
    'local traversal layers gitignore and prunes ignored directories',
    () async {
      Future<void> write(String path, String content) async {
        final file = File('${project.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
      }

      await write('.gitignore', '*.log\n!keep.log\n/root.txt\nblocked/\n');
      await write('src/.gitignore', '!restore.log\n/local.txt\n');
      await write('blocked/.gitignore', '!rescue.txt\n');
      for (final path in [
        'drop.log',
        'keep.log',
        'root.txt',
        'src/root.txt',
        'src/drop.log',
        'src/restore.log',
        'src/local.txt',
        'src/deep/local.txt',
        'blocked/rescue.txt',
        '.venv/a.txt',
        'venv/a.txt',
        '__pycache__/a.txt',
        'target/a.txt',
        'build/a.txt',
        'plain.txt',
      ]) {
        await write(path, 'needle');
      }
      // A normal file named like a default directory must remain searchable.
      await write('src/build', 'needle');
      final access = LocalWorkspaceFiles(
        project.path,
        protectedRoot: store.root.path,
        beforeCommit: () {},
      );
      final skipped = <String>[];
      final paths = (await access.files(skipped: skipped)).map((f) => f.path);
      expect(
        paths,
        containsAll([
          'keep.log',
          'src/root.txt',
          'src/restore.log',
          'src/deep/local.txt',
          'target/a.txt',
          'plain.txt',
          'src/build',
        ]),
      );
      for (final path in [
        'drop.log',
        'root.txt',
        'src/drop.log',
        'src/local.txt',
        'blocked/rescue.txt',
        '.venv/a.txt',
        'venv/a.txt',
        '__pycache__/a.txt',
        'build/a.txt',
      ]) {
        expect(paths, isNot(contains(path)), reason: path);
      }
      expect(skipped, isEmpty);
      final nested = (await access.files(path: 'src')).map((f) => f.path);
      expect(nested, contains('src/restore.log'));
      expect(nested, isNot(contains('src/drop.log')));
      expect(await access.files(path: 'blocked/rescue.txt'), isEmpty);
      final included = (await access.files(
        includeIgnored: true,
      )).map((f) => f.path);
      expect(
        included,
        containsAll(['blocked/rescue.txt', '.venv/a.txt', 'drop.log']),
      );
      // Direct reads and directory listings are not search filters.
      expect(utf8.decode((await access.read('drop.log')).$1), 'needle');
      expect(
        (await access.listDirectory('')).map((e) => e.name),
        contains('blocked'),
      );
      final grep = await call('workspace_grep', {
        'path': project.path,
        'pattern': 'needle',
      });
      expect(grep.text, contains('keep.log:1: needle'));
      expect(grep.text, isNot(contains('drop.log:1:')));
      expect(grep.text, isNot(contains('skipped_count:')));
    },
  );

  test(
    'native shell starts in same cwd and rejects invalid cwd before launch',
    () async {
      tools = WorkspaceToolset(
        store: store,
        workspaceIds: {'aicove'},
        runId: 'shell',
        enableShell: true,
        enableLocalFiles: true,
      );
      await call('workspace_open', {'path': project.path});
      final scope = ToolCallScope()..outcome = GateOutcome.allowed;
      final result = await scope.run(
        () => call('bash', {'command': 'pwd; printf shell > shell.txt'}),
      );
      expect(result.isError, false, reason: result.text);
      expect(await File('${project.path}/shell.txt').readAsString(), 'shell');
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
      await project.delete(recursive: true);
      final fallback = await scope.run(
        () => call('bash', {'command': 'printf fallback > fallback-shell.txt'}),
      );
      expect(fallback.isError, true, reason: fallback.text);
      expect(fallback.text, startsWith('directory_unavailable:'));
      expect(fallback.text, contains('请重新确认目标空间或路径后再执行修改'));
      expect(await store.stat('aicove', 'fallback-shell.txt'), isNull);
      expect(await tools.prompt(), isNot(contains('已切回默认空间')));
    },
  );

  test(
    'codemode bytes use native backend, keep artifacts managed and stop late writes',
    () async {
      await call('workspace_open', {'path': project.path});
      CodemodeScript script() => CodemodeScript(
        store: store,
        workspace: () => 'aicove',
        runId: 'code',
        owner: 'conversation',
        resolveFile: tools.resolveFile,
      );
      final write = await script().run(
        'await ws.writeBytes("bytes.bin", new Uint8Array([1,2,3])); text(await ws.readBytes("bytes.bin"));',
      );
      expect(write.isError, false, reason: write.text);
      expect(await File('${project.path}/bytes.bin').readAsBytes(), [1, 2, 3]);
      final out = await script().run(
        '// @options: {"max_output_tokens":2}\ntext("x".repeat(100));',
      );
      expect(out.isError, false, reason: out.text);
      final outputPath = (out.structured as Map)['fullOutputPath'] as String;
      expect(outputPath, startsWith(store.directoryOf('aicove').path));
      expect(
        (await call('read', {'path': outputPath})).text,
        contains('x' * 100),
      );
      expect(await Directory('${project.path}/.aicove').exists(), false);
      final stopped = await script().run(
        'throw Error("stop"); await ws.writeBytes("late", new Uint8Array([9]));',
      );
      expect(stopped.isError, true);
      expect(await File('${project.path}/late').exists(), false);
    },
  );

  test(
    'move/delete native files and preview root stay outside managed history',
    () async {
      String? root, page;
      tools = WorkspaceToolset(
        store: store,
        workspaceIds: {'aicove'},
        runId: 'preview',
        enableLocalFiles: true,
        runLocalWebApp: (r, p) async {
          root = r;
          page = p;
          return Uri.parse('http://local.localhost:47823/$p');
        },
      );
      await call('workspace_open', {'path': project.path});
      await call('write', {'path': 'a.txt', 'content': 'move'});
      expect(
        (await call('workspace_move', {
          'from': 'a.txt',
          'to': 'b.txt',
        })).isError,
        false,
      );
      expect(
        (await call('workspace_delete', {'path': 'b.txt'})).isError,
        false,
      );
      await File(
        '${project.path}/index.html',
      ).writeAsString('<h1>preview</h1>');
      final preview = await call('workspace_run', {'path': 'index.html'});
      expect(preview.isError, false, reason: preview.text);
      expect(root, await project.resolveSymbolicLinks());
      expect(page, 'index.html');
      expect(await store.runs('aicove'), isEmpty);
    },
  );

  test('broken links do not prevent opening or listing a directory', () async {
    await File('${project.path}/good.txt').writeAsString('good');
    await Link('${project.path}/broken').create('${temp.path}/missing');
    final opened = await call('workspace_open', {'path': project.path});
    expect(opened.isError, false, reason: opened.text);
    expect(
      opened.text,
      allOf(contains('good.txt'), contains('broken'), contains('skipped')),
    );
    final listed = await call('workspace_list', {});
    expect(listed.isError, false, reason: listed.text);
    expect(listed.text, contains('good.txt'));
  });

  test('symlink then parent segment has the same meaning as the OS', () async {
    final other = await Directory(
      '${temp.path}/other/child',
    ).create(recursive: true);
    await File('${temp.path}/other/a.txt').writeAsString('outside');
    await File('${project.path}/a.txt').writeAsString('project');
    await Link('${project.path}/link').create(other.path);
    final path = '${project.path}/link/../a.txt';
    expect((await call('read', {'path': path})).text, startsWith('outside'));
    expect(
      (await call('edit', {
        'path': path,
        'old_text': 'outside',
        'new_text': 'changed',
      })).isError,
      false,
    );
    expect(await File('${temp.path}/other/a.txt').readAsString(), 'changed');
    expect(await File('${project.path}/a.txt').readAsString(), 'project');
    final created = '${project.path}/link/../new.txt';
    expect(
      (await call('write', {'path': created, 'content': 'new'})).isError,
      false,
    );
    expect(await File('${temp.path}/other/new.txt').readAsString(), 'new');
    expect(await File('${project.path}/new.txt').exists(), false);
  });

  test(
    'moving and deleting a file link never moves or deletes its target',
    () async {
      final real = File('${project.path}/real');
      await real.writeAsString('keep');
      final link = Link('${project.path}/alias');
      await link.create(real.path);
      final moved = '${project.path}/renamed';
      expect(
        (await call('workspace_move', {
          'from': link.path,
          'to': moved,
        })).isError,
        false,
      );
      expect(
        await FileSystemEntity.type(moved, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await real.readAsString(), 'keep');
      expect((await call('workspace_delete', {'path': moved})).isError, false);
      expect(await real.readAsString(), 'keep');
    },
  );
  test(
    'host invocation closing during IO prevents a late native commit',
    () async {
      var active = true;
      final access = LocalWorkspaceFiles(
        project.path,
        protectedRoot: store.root.path,
        beforeCommit: () {},
      );
      final result = WorkspaceStore.guardCommits(() => active, () async {
        final write = access.write('late.txt', utf8.encode('late'));
        active = false;
        return write;
      });
      await expectLater(
        result,
        throwsA(predicate((e) => e.toString().contains('cancelled'))),
      );
      expect(await File('${project.path}/late.txt').exists(), false);
      expect(
        await project.list().any((e) => e.path.contains('.aicove-write-')),
        false,
      );
    },
  );
  test(
    'a native link to a managed file cannot delete the managed target',
    () async {
      await store.write(
        'aicove',
        'keep.txt',
        utf8.encode('keep'),
        runId: 'setup',
      );
      final link = Link('${project.path}/managed-link');
      await link.create('${store.directoryOf('aicove').path}/keep.txt');
      final output = await call('workspace_delete', {'path': link.path});
      expect(output.isError, true);
      expect(await store.stat('aicove', 'keep.txt'), isNotNull);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
  );
}
