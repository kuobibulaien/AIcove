import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_quickjs/process.dart';
import 'package:aicove_flutter/src/core/utils/desktop_process_environment.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_stdio_launch.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_script.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_shell.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_toolset.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_errors.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

Future<T> approved<T>(Future<T> Function() body) =>
    (ToolCallScope()
          ..outcome = GateOutcome.approved
          ..humanApproved = true)
        .run(body);

void main() {
  late Directory root;
  late WorkspaceStore store;
  late String ws;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('shell_h3_');
    store = await WorkspaceStore.open(root);
    ws = (await store.create(name: '命令测试')).id;
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<ToolOutput> run(
    String command, {
    Duration timeout = const Duration(seconds: 10),
    bool Function()? cancel,
  }) => approved(
    () => WorkspaceShell(
      store: store,
      workspace: ws,
      runId: 'shell',
      isCancelled: cancel,
    ).run(command, timeout: timeout),
  );
  File file(String path) => File('${store.directoryOf(ws).path}/$path');

  test('only desktop platforms assemble shell', () {
    for (final platform in ['macos', 'windows', 'linux', 'android', 'ios']) {
      expect(
        WorkspaceShell.available(platform: platform),
        ['macos', 'windows', 'linux'].contains(platform),
      );
    }
    for (final scripts in [false, true]) {
      final tools = WorkspaceToolset(
        store: store,
        workspaceIds: {ws},
        runId: 'background_or_role',
        enableScripts: scripts,
      ).tools();
      expect(tools.any((t) => t.name == 'bash'), isFalse);
    }
    final tool = WorkspaceToolset(
      store: store,
      workspaceIds: {ws},
      runId: 'assistant',
      enableShell: true,
    ).tools().first;
    expect(tool.name, 'bash');
    expect(tool.requiresHumanApproval, isFalse);
    expect(tool.managesDeadline, isTrue);
    expect(tool.executionTimeout, isNull);
  });
  test('channel keys reach only shells given them (ADR0109)', () async {
    final keyed = await approved(
      () => WorkspaceShell(
        store: store,
        workspace: ws,
        runId: 'keyed',
        environment: () => {'AICOVE_KEY_NOVELAI': 'pst-test'},
      ).run(r'printf "%s" "$AICOVE_KEY_NOVELAI" > key.txt'),
    );
    expect(keyed.isError, isFalse);
    expect(await file('key.txt').readAsString(), 'pst-test');
    final plain = await run(
      r'printf "%s" "${AICOVE_KEY_NOVELAI-unset}" > plain.txt',
    );
    expect(plain.isError, isFalse);
    expect(await file('plain.txt').readAsString(), 'unset');
  });
  test(
    'shell variables do not leak to unrelated child processes',
    () async {
      final result = await approved(
        () => WorkspaceShell(
          store: store,
          workspace: ws,
          runId: 'private_environment',
          environment: () => {'AICOVE_TEST_SHELL_PRIVATE': 'private'},
        ).run(r'printf "%s" "$AICOVE_TEST_SHELL_PRIVATE"'),
      );
      expect(result.isError, isFalse, reason: result.text);
      expect((result.structured as Map)['output'], 'private');
      expect(
        _hostContainsEnvironmentVariable('AICOVE_TEST_SHELL_PRIVATE'),
        isFalse,
      );
      final unrelated = await Process.run('/bin/sh', [
        '-c',
        r'printf "%s" "${AICOVE_TEST_SHELL_PRIVATE-unset}"',
      ]);
      expect(unrelated.exitCode, 0);
      expect(unrelated.stdout, 'unset');
    },
    skip: Platform.isWindows,
  );
  test(
    'desktop PATH preserves MCP precedence, home expansion and nvm',
    () async {
      for (final version in ['v9.20.0', 'v22.3.0', 'v22.10.0', 'invalid']) {
        await Directory(
          '${root.path}/.nvm/versions/node/$version/bin',
        ).create(recursive: true);
      }
      final parent = {'HOME': root.path, 'PATH': '/parent:/same'};
      final overrides = {'PATH': '~/tools:/same', 'TOKEN': 'private'};
      final env = desktopProcessEnvironment(
        parent: parent,
        overrides: overrides,
        platform: 'macos',
      );
      expect(env['PATH']!.split(':'), [
        '${root.path}/tools',
        '/same',
        '/parent',
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/usr/bin',
        '/bin',
        '${root.path}/.local/bin',
        '${root.path}/.cargo/bin',
        '${root.path}/.nvm/versions/node/v22.10.0/bin',
      ]);
      expect(env['TOKEN'], 'private');
      expect(parent['PATH'], '/parent:/same');
      expect(overrides['PATH'], '~/tools:/same');
      if (!Platform.isWindows) {
        expect(
          mcpProcessEnvironment(parent: parent, overrides: overrides),
          env,
        );
      }
    },
  );
  test('Windows shared environment preserves legacy MCP casing and order', () {
    final parent = {
      'Path': r'C:\Parent;C:\Same',
      'Token': 'parent',
      'z': 'last',
    };
    final overrides = {
      'PATH': r'c:\same;C:\User;C:\Parent',
      'TOKEN': 'child',
      'a': 'first',
    };
    final env = desktopProcessEnvironment(
      parent: parent,
      overrides: overrides,
      platform: 'windows',
    );
    expect(env.keys.toList(), ['Token', 'z', 'TOKEN', 'a', 'PATH']);
    expect(env['PATH'], r'c:\same;C:\User;C:\Parent;C:\Same');
    expect(env['Token'], 'parent');
    expect(env['TOKEN'], 'child');
    expect(env.containsKey('Path'), isFalse);
    if (Platform.isWindows) {
      expect(mcpProcessEnvironment(parent: parent, overrides: overrides), env);
    }
  });
  test(
    'native child environment preserves Unicode, equals and empty values',
    () async {
      expect(
        await _jobOutput(
          root.path,
          Platform.isWindows
              ? r'[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); [Console]::Write($env:AICOVE_TEST_ENV + "|" + $env:AICOVE_TEST_EMPTY)'
              : r'printf "%s|%s" "$AICOVE_TEST_ENV" "$AICOVE_TEST_EMPTY"',
          environment: {
            'AICOVE_TEST_ENV': '二号=值',
            if (Platform.isWindows) 'aicove_test_env': '二号=值',
            'AICOVE_TEST_EMPTY': '',
          },
        ),
        '二号=值|',
      );
    },
  );
  test(
    'shell gets GUI PATH completion with command variables first',
    () async {
      final result = await approved(
        () => WorkspaceShell(
          store: store,
          workspace: ws,
          runId: 'gui_path',
          environment: () => {
            'PATH': '/aicove/custom',
            'AICOVE_TEST_ENV': 'value',
          },
        ).run(r'printf "%s\n%s" "$PATH" "$AICOVE_TEST_ENV"'),
      );
      expect(result.isError, isFalse, reason: result.text);
      final output = (result.structured as Map)['output'] as String;
      expect(output, startsWith('/aicove/custom:'));
      expect(output, contains('/opt/homebrew/bin'));
      expect(output, contains('/usr/local/bin'));
      expect(output, endsWith('\nvalue'));
    },
    skip: Platform.isWindows,
  );
  test(
    'legacy setter copies and validates without changing the host',
    () async {
      addTearDown(() => DesktopJob.setEnvironment({}));
      final variables = {'AICOVE_TEST_ENV': 'saved'};
      DesktopJob.setEnvironment(variables);
      variables['AICOVE_TEST_ENV'] = 'mutated';
      for (final invalid in [
        {'': 'value'},
        {'BAD=NAME': 'value'},
        {'BAD\x00NAME': 'value'},
        {'AICOVE_TEST_ENV': 'bad\x00value'},
      ]) {
        expect(() => DesktopJob.setEnvironment(invalid), throwsArgumentError);
        expect(
          () => DesktopJob.start(root.path, 'echo never', environment: invalid),
          throwsArgumentError,
        );
      }
      expect(
        await _jobOutput(root.path, r'printf "%s" "$AICOVE_TEST_ENV"'),
        'saved',
      );
      expect(
        await _jobOutput(
          root.path,
          r'printf "%s" "$AICOVE_TEST_ENV"',
          environment: {'AICOVE_TEST_ENV': 'explicit'},
        ),
        'explicit',
      );
      expect(
        await _jobOutput(
          root.path,
          r'printf "%s" "${AICOVE_TEST_ENV-unset}"',
          environment: {},
        ),
        'unset',
      );
      expect(_hostContainsEnvironmentVariable('AICOVE_TEST_ENV'), isFalse);
    },
    skip: Platform.isWindows,
  );
  test(
    'concurrent isolates keep native child environments separate',
    () async {
      final cwd = root.path;
      final results = await Future.wait([
        for (final value in ['one', '二号=值']) _isolateJob(cwd, value),
      ]);
      expect(results, ['one', '二号=值']);
      expect(
        await _jobOutput(cwd, r'printf "%s" "${AICOVE_TEST_ENV-unset}"'),
        'unset',
      );
    },
    skip: Platform.isWindows,
  );
  test('denied or non-human approval cannot launch a command', () async {
    for (final outcome in [GateOutcome.denied, GateOutcome.approved]) {
      final scope = ToolCallScope()..outcome = outcome;
      final result = await scope.run(
        () => WorkspaceShell(
          store: store,
          workspace: ws,
          runId: 'unapproved',
        ).run('touch unapproved'),
      );
      expect(result.isError, isTrue);
      expect(await file('unapproved').exists(), isFalse);
    }
    expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
  });

  test(
    'command construction preserves exact commands, including Windows quotes',
    () {
      final line = WorkspaceShell.commandLine(
        'windows',
        'Write-Output "hello"',
      );
      expect(line.$1, 'powershell');
      expect(line.$2, ['-NoProfile', '-Command', 'Write-Output "hello"']);
      expect(
        DesktopJob.windowsCommandLine('Write-Output "hello"'),
        r'powershell -NoProfile -Command "Write-Output \"hello\""',
      );
      expect(
        DesktopJob.windowsCommandLine('echo x\\'),
        r'powershell -NoProfile -Command "echo x\\"',
      );
      expect(WorkspaceShell.commandLine('macos', 'echo x').$1, '/bin/sh');
      expect(WorkspaceShell.commandLine('macos', 'echo x').$2, [
        '-c',
        'echo x',
      ]);
      expect(WorkspaceShell.commandLine('linux', 'echo x').$1, '/bin/sh');
      expect(WorkspaceShell.commandLine('linux', 'echo x').$2, [
        '-c',
        'echo x',
      ]);
    },
  );
  test('approval card copies plan literally', () {
    final prompt = ApprovalPrompt.workspaceShell('笔记', 'echo hi\npwd');
    expect(prompt.title, '运行命令');
    expect(
      prompt.detail,
      '在空间「笔记」里执行：\necho hi\npwd\n命令可能改动空间以外的文件，命令造成的改动无法撤销',
    );
  });
  for (final seconds in [119, 120, 121, 599, 600, 601]) {
    test('shell deadline boundary $seconds', () {
      if (seconds > 0) {
        expect(WorkspaceShell.deadline(seconds), Duration(seconds: seconds));
      } else {
        expect(() => WorkspaceShell.deadline(seconds), throwsArgumentError);
      }
    });
  }
  test('default deadline is unlimited and invalid values fail', () {
    expect(WorkspaceShell.deadline(null), isNull);
    for (final value in [0, -1, 1.5, '120']) {
      expect(() => WorkspaceShell.deadline(value), throwsArgumentError);
    }
  });
  for (final ms in [4999, 5000, 5001]) {
    test('shell settle budget boundary $ms milliseconds', () {
      expect(
        WorkspaceShell.settleBudgetExhausted(Duration(milliseconds: ms)),
        ms >= 5000,
      );
    });
  }
  test(
    'tool policy allowance or explicit human approval launches a command',
    () async {
      final shell = WorkspaceShell(store: store, workspace: ws, runId: 'shell');
      expect((await shell.run('touch forbidden')).isError, isTrue);
      final result = await approved(() => shell.run('touch approved'));
      expect(result.isError, isFalse);
      expect(await file('forbidden').exists(), isFalse);
      expect(await file('approved').exists(), isTrue);
      final allowed = await (ToolCallScope()..outcome = GateOutcome.allowed)
          .run(() => shell.run('printf allowed'));
      expect(allowed.isError, isFalse);
    },
  );
  test('cwd, merged output, elapsed and nonzero exit are reported', () async {
    final result = await run(
      'printf stdout; printf stderr >&2; printf content > result.txt; exit 7',
    );
    expect(result.isError, isFalse);
    expect((result.structured as Map)['exit_code'], 7);
    expect(result.text, contains('stdoutstderr'));
    expect(result.text, contains('exit_code: 7'));
    expect(result.text, contains('elapsed_ms:'));
    expect(await file('result.txt').readAsString(), 'content');
    final row = (await store.index.fetch(
      'SELECT * FROM files WHERE ws=? AND path=?',
      [ws, 'result.txt'],
    )).single;
    expect(row.read<int>('size'), 7);
    expect(
      await store.index.fetch('SELECT * FROM command_changes'),
      hasLength(1),
    );
    final undo = await store.undoRun(ws, 'shell');
    expect(undo.undone, 0);
    expect(
      (await store.runs(ws)).singleWhere((r) => r.runId == 'shell').undone,
      isFalse,
    );
    expect(undo.conflicts, isEmpty);
    expect(undo.commandMessages, ['命令造成的改动不能撤销：result.txt']);
    expect((await store.undoRun(ws, 'shell')).commandChanges, ['result.txt']);
    expect(await file('result.txt').readAsString(), 'content');
  });
  test(
    'metadata removed/replaced with a link is restored without following it',
    () async {
      final before = await file('.aicove/workspace.json').readAsString();
      final elsewhere = Directory('${root.path}/outside')..createSync();
      File('${elsewhere.path}/keep').writeAsStringSync('safe');
      final result = await run(
        'rm -rf .aicove; ln -s "${elsewhere.path}" .aicove; printf new > normal',
      );
      expect(result.isError, isFalse, reason: result.text);
      expect(
        await FileSystemEntity.type(file('.aicove').path, followLinks: false),
        FileSystemEntityType.directory,
      );
      expect(await file('.aicove/workspace.json').readAsString(), before);
      expect(await File('${elsewhere.path}/keep').readAsString(), 'safe');
    },
  );
  test(
    'metadata outputs are restored exactly, shell changes are deleted/moved/indexed',
    () async {
      await store.write(ws, 'old', utf8.encode('old'), runId: 'earlier');
      await store.write(ws, 'delete', utf8.encode('delete'), runId: 'earlier');
      await store.write(
        ws,
        '.aicove/outputs/keep.txt',
        utf8.encode('keep'),
        runId: hostRunId,
        allowHost: true,
      );
      final result = await run(
        'mv old moved; rm delete; printf tamper > .aicove/outputs/keep.txt; touch .aicove/extra',
      );
      expect(result.isError, isFalse, reason: result.text);
      expect(await file('.aicove/outputs/keep.txt').readAsString(), 'keep');
      expect(await file('.aicove/extra').exists(), isFalse);
      final undo = await store.undoRun(ws, 'shell');
      expect(undo.commandChanges, containsAll(['old', 'moved', 'delete']));
      expect(await file('moved').readAsString(), 'old');
      expect(await file('delete').exists(), isFalse);
    },
  );
  test('same size and same mtime content change is detected by hash', () async {
    await store.write(ws, 'same', utf8.encode('before'), runId: 'first');
    final old = (await store.stat(ws, 'same'))!.revision;
    final modified = await file('same').lastModified();
    final lease = await store.beginCommand(ws, 'shell');
    await file('same').writeAsString('after!');
    await file('same').setLastModified(modified);
    final scan = await store.finishCommand(lease);
    expect(scan.changed, contains('same'));
    expect((await store.stat(ws, 'same'))!.revision, isNot(old));
  });
  test(
    'lease blocks writes, moves, deletes, undo and a second shell across connections/isolate',
    () async {
      await store.write(ws, 'old', utf8.encode('old'), runId: 'first');
      final revision = (await store.stat(ws, 'old'))!.revision;
      final lease = await store.beginCommand(ws, 'shell');
      for (final action in <Future<Object?> Function()>[
        () => store.write(ws, 'new', utf8.encode('x'), runId: 'other'),
        () => store.move(
          ws,
          'old',
          'other',
          expectedRevision: revision,
          runId: 'other',
        ),
        () =>
            store.delete(ws, 'old', expectedRevision: revision, runId: 'other'),
        () => store.undoRun(ws, 'first'),
        () => store.beginCommand(ws, 'second'),
      ]) {
        await expectLater(
          action(),
          throwsA(
            isA<WorkspaceException>().having((e) => e.code, 'code', 'busy'),
          ),
        );
      }
      final answer = await _isolateWrite(root.path, ws);
      expect(answer, 'busy');
      await store.finishCommand(lease);
      await store.write(ws, 'new', utf8.encode('x'), runId: 'after');
    },
  );
  test(
    'commands of one run share the lease and the last one scans once',
    () async {
      final metadata = await file('.aicove/workspace.json').readAsString();
      final results = await Future.wait([
        run('touch a_started; while [ ! -e b_started ]; do sleep 0.01; done'),
        run('touch b_started; while [ ! -e a_started ]; do sleep 0.01; done'),
        run('printf c > c; printf tamper > .aicove/workspace.json'),
      ]);
      for (final result in results) {
        expect(result.isError, isFalse, reason: result.text);
      }
      expect(await file('.aicove/workspace.json').readAsString(), metadata);
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
      expect(await store.stat(ws, 'c'), isNotNull);
      expect(
        (await store.undoRun(ws, 'shell')).commandChanges,
        containsAll(['a_started', 'b_started', 'c']),
      );
      await store.write(ws, 'after', utf8.encode('x'), runId: 'other');
    },
  );
  test(
    'group stays locked until its last member leaves, then accepts writes',
    () async {
      final first = await store.beginCommand(ws, 'shell');
      final second = await store.beginCommand(ws, 'shell');
      expect(second.id, first.id);
      await expectLater(
        store.beginCommand(ws, 'other_run'),
        throwsA(
          isA<WorkspaceException>()
              .having((e) => e.code, 'code', 'busy')
              .having((e) => e.message, 'message', contains('命令正在运行')),
        ),
      );
      await file('late').writeAsString('late');
      expect((await store.finishCommand(first)).changed, isEmpty);
      await expectLater(
        store.write(ws, 'blocked', utf8.encode('no'), runId: 'other'),
        throwsA(isA<WorkspaceException>()),
      );
      expect((await store.finishCommand(second)).changed, ['late']);
      await store.write(ws, 'free', utf8.encode('yes'), runId: 'other');
    },
  );
  test('an unsettled member leaves the whole group for recovery', () async {
    final first = await store.beginCommand(ws, 'shell');
    final second = await store.beginCommand(ws, 'shell');
    await first.releaseForRecovery();
    await file('leaked').writeAsString('x');
    await expectLater(store.finishCommand(second), throwsStateError);
    expect(
      await store.index.fetch('SELECT * FROM shell_intents'),
      hasLength(1),
    );
    await store.recoverCommands();
    expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
    expect(await store.stat(ws, 'leaked'), isNotNull);
  });
  test(
    'unfinished command intent restores metadata and scans on startup',
    () async {
      final before = await file('.aicove/workspace.json').readAsString();
      final lease = await store.beginCommand(ws, 'crashed');
      await file('.aicove/workspace.json').writeAsString('tamper');
      await file('interrupted').writeAsString('partial');
      await lease.releaseForRecovery();
      await store.close();
      store = await WorkspaceStore.open(root);
      expect(await file('.aicove/workspace.json').readAsString(), before);
      expect((await store.stat(ws, 'interrupted'))!.size, 7);
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
      expect((await store.undoRun(ws, 'crashed')).commandMessages, [
        '命令造成的改动不能撤销：interrupted',
      ]);
      await store.recoverCommands(); // Idempotent.
    },
  );

  test(
    'same run undoes later file-tool writes but skips command and its predecessors',
    () async {
      await store.write(ws, 'mixed', utf8.encode('first'), runId: 'shell');
      expect((await run('printf command > mixed')).isError, isFalse);
      await store.write(
        ws,
        'mixed',
        utf8.encode('later'),
        expectedRevision: (await store.stat(ws, 'mixed'))!.revision,
        runId: 'shell',
      );
      final result = await store.undoRun(ws, 'shell');
      expect(result.undone, 1);
      expect(result.conflicts, isEmpty);
      expect(result.commandMessages, ['命令造成的改动不能撤销：mixed']);
      expect(await file('mixed').readAsString(), 'command');
    },
  );
  test(
    'version 1 index upgrades additively and preserves existing undo',
    () async {
      await store.write(ws, 'prior', utf8.encode('prior'), runId: 'prior');
      await store.index.customStatement('DROP TABLE shell_intents');
      await store.index.customStatement('DROP TABLE command_changes');
      await store.index.customStatement('PRAGMA user_version=1');
      await store.close();
      store = await WorkspaceStore.open(root);
      expect((await store.stat(ws, 'prior'))!.size, 5);
      expect((await store.undoRun(ws, 'prior')).undone, 1);
      expect((await run('printf migrated > migrated')).isError, isFalse);
    },
  );
  test(
    'incomplete preparation is discarded without restoring an incomplete snapshot',
    () async {
      final lease = await store.beginCommand(ws, 'preparing');
      await store.index.immediate(
        () => store.index.run(
          "UPDATE shell_intents SET phase='preparing' WHERE id=?",
          [lease.id],
        ),
      );
      await Directory('${lease.backup.path}/metadata').delete(recursive: true);
      final original = await file('.aicove/workspace.json').readAsString();
      await lease.releaseForRecovery();
      await store.close();
      store = await WorkspaceStore.open(root);
      expect(await file('.aicove/workspace.json').readAsString(), original);
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
    },
  );
  test(
    'missing complete backup fails closed without deleting current metadata',
    () async {
      final lease = await store.beginCommand(ws, 'missing');
      final saved = Directory('${lease.backup.path}/metadata');
      await saved.rename('${lease.backup.path}/held');
      final original = await file('.aicove/workspace.json').readAsString();
      await expectLater(
        store.finishCommand(lease),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file('.aicove/workspace.json').readAsString(), original);
      await expectLater(
        store.write(ws, 'blocked', utf8.encode('no'), runId: 'other'),
        throwsA(isA<WorkspaceException>()),
      );
      await Directory('${lease.backup.path}/held').rename(saved.path);
      await store.recoverCommands();
      expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
    },
  );
  test(
    'live command owns workspace write lock until process settles and scan completes',
    () async {
      var cancelled = false;
      final pending = run('touch started; sleep 30', cancel: () => cancelled);
      try {
        for (var i = 0; i < 200 && !await file('started').exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await file('started').exists(), isTrue);
        await expectLater(
          store.write(ws, 'competing', utf8.encode('no'), runId: 'other'),
          throwsA(isA<WorkspaceException>()),
        );
      } finally {
        cancelled = true;
        await pending;
      }
      await store.write(
        ws,
        'after_command',
        utf8.encode('yes'),
        runId: 'other',
      );
    },
  );
  for (final cancel in [false, true]) {
    test('timeout/cancel kills children and grandchildren ($cancel)', () async {
      var stopped = false;
      final timer = Timer(
        const Duration(milliseconds: 500),
        () => stopped = true,
      );
      try {
        final result = await run(
          'sleep 30 & echo \$! > child.pid; (sleep 30 & echo \$! > grand.pid; wait) & wait',
          timeout: Duration(milliseconds: cancel ? 5000 : 500),
          cancel: () => cancel && stopped,
        );
        expect(result.isError, isTrue);
        expect(result.text, contains(cancel ? 'cancelled' : 'timed out'));
        for (final name in ['child.pid', 'grand.pid']) {
          final pid = int.parse((await file(name).readAsString()).trim());
          final state = await Process.run('/bin/sh', [
            '-c',
            'ps -p $pid -o stat=',
          ]);
          expect(
            (state.stdout as String).trim(),
            anyOf(isEmpty, startsWith('Z')),
          );
        }
        expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
      } finally {
        timer.cancel();
      }
    });
  }
  test(
    'successful shell also stops background writers before restoring metadata',
    () async {
      final result = await run('(sleep 1; printf late > late) & printf done');
      expect(result.isError, isFalse, reason: result.text);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(await file('late').exists(), isFalse);
    },
  );
  for (final n in [1999, 2000, 2001]) {
    test('shell output line boundary $n', () {
      final output = WorkspaceScriptOutput()
        ..addChunk('${List.filled(n, 'line').join('\n')}\n');
      expect(
        output.modelText.split('\n').where((s) => s.isNotEmpty),
        hasLength(n.clamp(0, 2000)),
      );
      expect(output.truncated, n > 2000);
    });
  }
  for (final cap in [50 * 1024, 8 * 1024 * 1024]) {
    for (final n in [cap - 1, cap, cap + 1]) {
      test('shell raw output byte boundary $n for cap $cap', () {
        final output = WorkspaceScriptOutput()..addChunk('x' * n);
        if (cap == 50 * 1024) {
          expect(utf8.encode(output.modelText).length, n.clamp(0, cap));
          expect(output.truncated, n > cap);
        } else {
          expect(output.fileBytes.length, n.clamp(0, cap));
          expect(output.fileTruncated, n > cap);
        }
      });
    }
  }
  test(
    'real output is bounded including status/footer and persisted tail stays 8 MiB',
    () async {
      final result = await run("head -c 8388609 /dev/zero | tr '\\000' x");
      expect(result.isError, isFalse, reason: result.text);
      expect(utf8.encode(result.text).length, lessThanOrEqualTo(50 * 1024));
      expect(result.text, contains('only the last 8 MiB retained'));
      final path = RegExp(
        r'full output: (\S+)',
      ).firstMatch(result.text)!.group(1)!;
      final bytes = await file(path).readAsBytes();
      expect(bytes.length, 8 * 1024 * 1024);
      expect(utf8.decode(bytes), contains('exit_code: 0'));
      expect(
        await store.runs(ws),
        isEmpty,
      ); // Output is host-owned, not a command mutation.
    },
  );

  test(
    'case-only rename leaves the new live row, not the old tombstone',
    () async {
      await store.write(ws, 'lower.txt', utf8.encode('same'), runId: 'prior');
      final result = await run('mv lower.txt LOWER.txt');
      expect(result.isError, isFalse, reason: result.text);
      final rows = await store.index.fetch(
        "SELECT path FROM files WHERE ws=? AND revision<>'' AND fold='lower.txt'",
        [ws],
      );
      expect(rows.single.read<String>('path'), 'LOWER.txt');
    },
  );
  test('FIFO does not hang recovery scanning', () async {
    final result = await run('mkfifo pipe');
    expect(result.isError, isTrue);
    expect(result.text, contains('pipe'));
    expect(await store.index.fetch('SELECT * FROM shell_intents'), isEmpty);
  });
  for (final size in [
    32 * 1024 * 1024 - 1,
    32 * 1024 * 1024,
    32 * 1024 * 1024 + 1,
  ]) {
    test('full read of externally produced file has no size cap $size', () async {
      final handle = await file('large').open(mode: FileMode.write);
      await handle.truncate(size);
      await handle.close();
      expect((await store.read(ws, 'large')).$1.length, size);
      expect(
        (await store.readRange(ws, 'large', offset: 0, length: 1)).length,
        1,
      );
    });
  }
  test(
    'unsafe links are not followed or indexed and produce an error',
    () async {
      final result = await run('ln -s /etc/passwd escape');
      expect(result.isError, isTrue);
      expect(result.text, contains('Cannot index unsafe paths: escape'));
      expect(await store.stat(ws, 'escape'), isNull);
    },
  );
}

bool _hostContainsEnvironmentVariable(String name) {
  final libc = ffi.DynamicLibrary.process();
  final allocate = libc
      .lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.IntPtr, ffi.IntPtr),
        ffi.Pointer<ffi.Void> Function(int, int)
      >('calloc');
  final free = libc
      .lookupFunction<
        ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)
      >('free');
  final getenv = libc
      .lookupFunction<
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>),
        ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>)
      >('getenv');
  final bytes = utf8.encode(name);
  final key = allocate(bytes.length + 1, 1);
  if (key == ffi.nullptr) throw StateError('Cannot allocate environment name');
  try {
    key.cast<ffi.Uint8>().asTypedList(bytes.length + 1).setAll(0, bytes);
    return getenv(key.cast()) != ffi.nullptr;
  } finally {
    free(key);
  }
}

Future<String> _jobOutput(
  String cwd,
  String command, {
  Map<String, String>? environment,
}) async {
  final job = DesktopJob.start(cwd, command, environment: environment);
  final bytes = <int>[];
  final watch = Stopwatch()..start();
  try {
    while (watch.elapsed < const Duration(seconds: 10)) {
      final chunk = job.read();
      if (chunk == null) {
        final status = job.exitCode;
        if (status != null) {
          if (status != 0) throw StateError('Child exited with $status');
          return utf8.decode(bytes);
        }
      } else {
        bytes.addAll(chunk);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('Native job did not finish');
  } finally {
    job.kill();
    job.close();
  }
}

Future<String> _isolateJob(String cwd, String value) => Isolate.run(() async {
  DesktopJob.setEnvironment({'AICOVE_TEST_ENV': value});
  return _jobOutput(
    cwd,
    r'''sleep 0.05; /bin/sh -c 'printf "%s" "$AICOVE_TEST_ENV"' ''',
  );
});

Future<String> _isolateWrite(String root, String workspace) =>
    Isolate.run(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final another = await WorkspaceStore.open(Directory(root));
      try {
        await another.write(
          workspace,
          'isolate',
          utf8.encode('x'),
          runId: 'other',
        );
        return 'written';
      } on WorkspaceException catch (e) {
        return e.code;
      } finally {
        await another.close();
      }
    });
