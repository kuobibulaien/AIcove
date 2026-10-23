import 'dart:convert';
import 'dart:async';
import 'extension_test_support.dart';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/packages/aicove_package.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_script.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_skill_tools.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_store.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/workspace/application/workspace_shell.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PackageStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('extensions_');
    store = PackageStore(Directory('${root.path}/packages'));
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'resource snapshots cannot be mutated by an importer or a later caller',
    () {
      final files = skillFiles();
      final package = AicovePackage.parse(files);
      files['references/value.txt']![0] = 0;
      expect(
        utf8.decode(package.files['references/value.txt']!),
        startsWith('resource-secret'),
      );
      expect(
        () => package.files['references/value.txt']![0] = 1,
        throwsUnsupportedError,
      );
      expect(() => package.files['new-file'] = [1], throwsUnsupportedError);
    },
  );

  test(
    'imports standard directory and single-folder zip with scripts/assets/hidden resources',
    () async {
      final directory = Directory('${root.path}/source')..createSync();
      for (final e in skillFiles().entries) {
        final file = File('${directory.path}/${e.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(e.value);
      }
      final first = await store.importDirectory(directory);
      expect(first.id, 'sample-skill');
      expect(first.directory, '${store.root.path}/sample-skill');
      expect(first.skills.single.content, startsWith('Use scripts/answer.js'));
      expect(
        first.files.keys,
        containsAll([
          'scripts/answer.js',
          'assets/template.bin',
          '.config/template.txt',
        ]),
      );
      final zipped = await store.importZip(
        zip({
          for (final e in skillFiles().entries) 'wrapper/${e.key}': e.value,
        }),
      );
      expect(zipped.id, first.id);
      expect(
        (await store.list()).single.files.keys,
        containsAll(first.files.keys),
      );
    },
  );

  test(
    'manifest skill.dir declares its complete subtree but not neighboring files',
    () {
      final files = {
        for (final e in skillFiles().entries) 'skills/one/${e.key}': e.value,
        'aicove-package.json': utf8.encode(
          jsonEncode({
            'schema': 1,
            'id': 'dirs',
            'name': 'Dirs',
            'version': '1',
            'contents': [
              {'type': 'skill', 'dir': 'skills/one'},
            ],
          }),
        ),
      };
      final package = AicovePackage.parse(files);
      expect(package.skills.single.dir, 'skills/one');
      expect(
        () => AicovePackage.parse({
          ...files,
          'neighbor.txt': [1],
        }),
        throwsA(isA<PackageFormatException>()),
      );
    },
  );

  test(
    'rejects traversal, absolute/Windows paths, case and Unicode duplicate names',
    () async {
      for (final path in [
        '../x',
        'a/../../x',
        '/x',
        'C:/x',
        r'a\x',
        'a/./x',
        'a//x',
      ]) {
        await expectLater(
          store.importFiles({
            ...skillFiles(),
            path: [1],
          }),
          throwsA(isA<PackageFormatException>()),
          reason: path,
        );
        await expectLater(
          store.importZip(
            zip({
              ...skillFiles(),
              path: [1],
            }),
          ),
          throwsA(isA<PackageFormatException>()),
          reason: path,
        );
      }
      for (final pair in [('a.txt', 'A.txt'), ('é.txt', 'e\u0301.txt')]) {
        await expectLater(
          store.importFiles({
            ...skillFiles(),
            pair.$1: [1],
            pair.$2: [2],
          }),
          throwsA(isA<PackageFormatException>()),
        );
      }
    },
  );

  test('rejects root/directory/file links and zip symlinks', () async {
    final source = Directory('${root.path}/src')..createSync();
    File('${source.path}/SKILL.md').writeAsBytesSync(skillFiles()['SKILL.md']!);
    final link = Link('${root.path}/linked')..createSync(source.path);
    await expectLater(
      store.importDirectory(Directory(link.path)),
      throwsA(isA<PackageFormatException>()),
    );
    Link('${source.path}/linked-file').createSync('/etc/passwd');
    await expectLater(
      store.importDirectory(source),
      throwsA(isA<PackageFormatException>()),
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'SKILL.md',
          skillFiles()['SKILL.md']!.length,
          skillFiles()['SKILL.md']!,
        ),
      );
    archive.addFile(
      ArchiveFile('linked', 11, utf8.encode('/etc/passwd'))
        ..mode = 0xa1ff
        ..isSymbolicLink = true,
    );
    await expectLater(
      store.importZip(ZipEncoder().encode(archive)!),
      throwsA(isA<PackageFormatException>()),
    );
  });

  test(
    'enforces 8 MiB file, 20 MiB package and 1000 file limits including inflated zip',
    () async {
      final big = List<int>.filled(PackageStore.maxFileBytes + 1, 65);
      for (final files in [
        {...skillFiles(), 'assets/big': big},
        {
          ...skillFiles(),
          for (var i = 0; i < 3; i++)
            'assets/$i': List<int>.filled(7 * 1024 * 1024, 65),
        },
        {
          ...skillFiles(),
          for (var i = 0; i < 1000; i++) 'assets/$i': [1],
        },
      ]) {
        await expectLater(
          store.importFiles(files),
          throwsA(isA<PackageFormatException>()),
        );
        await expectLater(
          store.importZip(zip(files)),
          throwsA(isA<PackageFormatException>()),
        );
      }
      final accepted = {
        ...skillFiles(),
        'assets/max': List<int>.filled(PackageStore.maxFileBytes, 65),
      };
      expect(
        (await store.importFiles(accepted)).files['assets/max']!.length,
        PackageStore.maxFileBytes,
      );
    },
  );

  test(
    'skill inventory, text pagination, binary metadata and desktop shell guidance',
    () async {
      final package = await store.importFiles(skillFiles());
      final read = PackageSkillTools(package).tools().first;
      final inventory = (await read.invoke({'name': 'sample-skill'})).text;
      expect(inventory, contains('scripts/answer.js'));
      expect(inventory, contains('Skill directory: ${package.directory}'));
      expect(
        inventory,
        contains('commands follow the current tool authorization policy'),
      );
      expect(
        inventory,
        contains('Desktop commands run with the current user permissions'),
      );
      final page =
          jsonDecode(
                (await read.invoke({
                  'name': 'sample-skill',
                  'path': 'references/value.txt',
                  'offset': 2,
                  'limit': 1,
                })).text,
              )
              as Map;
      expect(page['text'], 'second');
      expect(page['next_offset'], 3);
      final binary =
          jsonDecode(
                (await read.invoke({
                  'name': 'sample-skill',
                  'path': 'assets/template.bin',
                })).text,
              )
              as Map;
      expect(binary['binary'], true);
      expect(binary['size'], 3);
      expect(binary.containsKey('text'), false);
      expect(
        (await read.invoke({
          'name': 'sample-skill',
          'path': '../other',
        })).isError,
        true,
      );
      expect(
        (await read.invoke({
          'name': 'sample-skill',
          'limit': 0,
          'path': 'references/value.txt',
        })).isError,
        true,
      );
      // Availability does not bypass the shared tool gate.
      final shell = WorkspaceShell.available(platform: 'macos');
      expect(shell, true);
    },
  );

  test(
    'skill JS reads only its own snapshot and cannot write package files',
    () async {
      final package = AicovePackage.parse(skillFiles());
      final run = PackageSkillTools(package).tools().last;
      final output = await run.invoke({
        'name': 'sample-skill',
        'path': 'scripts/answer.js',
        'args': {'suffix': 'ok'},
      });
      expect(output.isError, false, reason: output.text);
      expect(output.text, 'resource-secret\nsecond\nthird:ok');
      for (final code in [
        'return await skill.readText("../outside.txt");',
        'return await skill.readText("other/secret.txt");',
        'await ws.writeBytes("references/value.txt", "AA==");',
        'text(typeof skill.writeText);',
      ]) {
        final altered = AicovePackage.parse({
          ...skillFiles(),
          'scripts/probe.js': utf8.encode(code),
        });
        final result = await PackageSkillTools(altered).tools().last.invoke({
          'name': 'sample-skill',
          'path': 'scripts/probe.js',
        });
        if (code.contains('typeof')) {
          expect(result.text, 'undefined');
        } else {
          expect(result.isError, true, reason: result.text);
        }
      }
      expect(
        (await run.invoke({
          'name': 'sample-skill',
          'path': '../outside.js',
        })).isError,
        true,
      );
    },
  );

  test(
    'script registration, error/timeout isolation and next invocation rebuild',
    () async {
      final script = PackageScript(
        AicovePackage.parse(scriptFiles(scriptSource)),
        timeout: const Duration(milliseconds: 200),
      );
      await script.load();
      expect(script.loadError, isNull);
      expect(script.prompts, ['script-prompt']);
      final tool = script.tools().single;
      expect(tool.name, 'pkg_4_demo_answer');
      expect(tool.inputSchema!['required'], ['value']);
      expect((await tool.invoke({'value': 7})).text, 'count:1\n21');
      expect((await tool.invoke({'value': 1, 'fail': true})).isError, true);
      expect((await tool.invoke({'value': 1, 'loop': true})).isError, true);
      expect((await tool.invoke({'value': 1, 'heap': true})).isError, true);
      expect((await tool.invoke({'value': 8})).text, 'count:1\n24');
      final cancellation = KernelCancellation()..cancel();
      final result = await ToolCallContext(
        sessionId: 't',
        turnId: 'r',
        round: 1,
        toolCallId: 'c',
        cancellation: cancellation,
      ).run(() => tool.invoke({'value': 9}));
      expect(result.isError, true);
      expect(result.text, contains('cancel'));
    },
  );

  test(
    'load failures and invalid registrations skip one plugin, not others; role selection revokes next run',
    () async {
      final good = PackagePlugin(
        AicovePackage.parse(scriptFiles(scriptSource)),
      );
      final bad = PackagePlugin(
        AicovePackage.parse(
          scriptFiles('throw new Error("bad-load");', id: 'bad'),
        ),
      );
      final skill = PackagePlugin(AicovePackage.parse(skillFiles()));
      final plugins = [good, bad, skill];
      final selected = {
        'pkg:demo',
        'pkg:bad',
        'pkg:sample-skill',
        'pkg:missing',
      };
      final on = await resolveTaskPluginCapabilities(plugins, selected);
      expect(
        on.prompts['pkg:demo'],
        contains('package-prompt\n\nscript-prompt'),
      );
      expect(bad.script.loadError, contains('bad-load'));
      expect(
        on.tools.map((t) => t.name),
        containsAll([
          'pkg_4_demo_answer',
          'read_skill_sample-skill',
          'run_skill_js_sample-skill',
        ]),
      );
      final off = await resolveTaskPluginCapabilities(plugins, {'pkg:bad'});
      expect(off.tools, isEmpty);
      expect(off.prompts.keys, isNot(contains('pkg:demo')));
      expect(
        (await resolveTaskPluginCapabilities(plugins, null)).tools,
        isEmpty,
      );
      expect(
        (await on.tools.firstWhere((t) => t.name == 'pkg_4_demo_answer').invoke(
          {'value': 3},
        )).text,
        contains('9'),
      );
      final invalid = PackageScript(
        AicovePackage.parse(
          scriptFiles('aicove.registerTool({name:"bad name",handler:()=>1});'),
        ),
      );
      await invalid.load();
      expect(invalid.tools(), isEmpty);
      expect(invalid.loadError, isNotNull);
    },
  );
  test(
    'plugin registration tight loops time out and in-flight handler cancellation stops JS',
    () async {
      final bad = PackageScript(
        AicovePackage.parse(scriptFiles('while(true) {}')),
        timeout: const Duration(milliseconds: 100),
      );
      await bad.load();
      expect(bad.loadError, isNotNull);
      expect(bad.tools(), isEmpty);
      final good = PackageScript(
        AicovePackage.parse(scriptFiles(scriptSource)),
        timeout: const Duration(seconds: 3),
      );
      await good.load();
      final cancellation = KernelCancellation();
      final timer = Timer(
        const Duration(milliseconds: 40),
        cancellation.cancel,
      );
      final watch = Stopwatch()..start();
      final result = await ToolCallContext(
        sessionId: 't',
        turnId: 'r',
        round: 1,
        toolCallId: 'c',
        cancellation: cancellation,
      ).run(() => good.tools().single.invoke({'value': 1, 'loop': true}));
      timer.cancel();
      expect(result.isError, true);
      expect(result.text.toLowerCase(), contains('cancel'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(
        (await good.tools().single.invoke({'value': 2})).text,
        contains('6'),
      );
    },
  );
}
