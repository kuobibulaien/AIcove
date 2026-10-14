import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/content_tag_spec.dart';
import 'package:aicove_flutter/src/features/plugins/packages/aicove_package.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_store.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> manifest({
  List<Object?>? contents,
  Map<String, Object?> extra = const {},
}) => {
  'schema': 1,
  'id': 'demo',
  'name': '示例包',
  'version': '1.0.0',
  'description': '测试用',
  'contents':
      contents ??
      [
        {'type': 'prompt', 'text': '说话时带一点诗意。'},
        {
          'type': 'tags',
          'tags': [
            {
              'name': 'mood',
              'aliases': ['feeling'],
            },
            {'name': 'secret', 'display': 'hidden'},
          ],
        },
        {
          'type': 'skill',
          'name': 'guide',
          'title': '写诗指南',
          'file': 'skills/guide.md',
        },
      ],
  ...extra,
};

Map<String, List<int>> files(
  Map<String, Object?> manifest, {
  Map<String, String> others = const {'skills/guide.md': '# 指南\n押韵。'},
}) => {
  AicovePackage.manifestName: utf8.encode(jsonEncode(manifest)),
  for (final entry in others.entries) entry.key: utf8.encode(entry.value),
};

Matcher rejects(String fragment) => throwsA(
  isA<PackageFormatException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('parse', () {
    test('reads prompts, tags and skills', () {
      final package = AicovePackage.parse(files(manifest()));
      expect(package.pluginId, 'pkg:demo');
      expect(package.prompts, ['说话时带一点诗意。']);
      expect([for (final t in package.tags) t.name], ['mood', 'secret']);
      expect(package.tags.first.aliases, {'feeling'});
      expect(package.tags.last.hidden, isTrue);
      expect(package.skills.single.content, '# 指南\n押韵。');

      final provider = package.contentTagProvider(
        readSkillTool: 'read_skill_demo',
      );
      expect(provider.providerId, 'pkg:demo');
      expect(provider.toolNames, {'read_skill_demo'});
      expect(
        [for (final spec in provider.tagSpecs) (spec.ownerId, spec.display)],
        [
          ('pkg:demo', ContentTagDisplay.text),
          ('pkg:demo', ContentTagDisplay.hidden),
        ],
      );
    });

    test('rejects unknown fields anywhere', () {
      expect(
        () => AicovePackage.parse(files(manifest(extra: {'script': 'x'}))),
        rejects('script'),
      );
      expect(
        () => AicovePackage.parse(
          files(
            manifest(
              contents: [
                {'type': 'prompt', 'text': 'a', 'position': 'top'},
              ],
            ),
          ),
        ),
        rejects('position'),
      );
      expect(
        () => AicovePackage.parse(
          files(
            manifest(
              contents: [
                {
                  'type': 'tags',
                  'tags': [
                    {'name': 'mood', 'replace': '<b>\$1</b>'},
                  ],
                },
              ],
            ),
          ),
        ),
        rejects('replace'),
      );
    });

    test('rejects executable or unknown content', () {
      expect(
        () => AicovePackage.parse(
          files(
            manifest(
              contents: [
                {'type': 'script', 'file': 'run.js'},
              ],
            ),
            others: {'run.js': 'alert(1)'},
          ),
        ),
        rejects('script'),
      );
      expect(
        () => AicovePackage.parse(
          files(manifest(), others: {'skills/guide.md': 'x', 'hook.js': 'x'}),
        ),
        rejects('hook.js'),
      );
      expect(
        () => AicovePackage.parse(
          files(
            manifest(
              contents: [
                {
                  'type': 'tags',
                  'tags': [
                    {'name': 'card', 'display': 'html'},
                  ],
                },
              ],
            ),
          ),
        ),
        rejects('html'),
      );
    });

    test('keeps skill files inside the package', () {
      for (final path in [
        '../outside.md',
        '/abs.md',
        'skills/../x.md',
        'a.txt',
      ]) {
        expect(
          () => AicovePackage.parse(
            files(
              manifest(
                contents: [
                  {'type': 'skill', 'name': 'guide', 'file': path},
                ],
              ),
              others: {path: 'x'},
            ),
          ),
          rejects('技能文件'),
          reason: path,
        );
      }
      expect(
        () => AicovePackage.parse(
          files(
            manifest(
              contents: [
                {'type': 'skill', 'name': 'guide', 'file': 'missing.md'},
              ],
            ),
            others: const {},
          ),
        ),
        rejects('缺少技能文件'),
      );
    });

    test('rejects bad ids, schemas and missing manifest', () {
      expect(
        () => AicovePackage.parse(files(manifest(extra: {'id': 'Bad Id'}))),
        rejects('id'),
      );
      expect(
        () => AicovePackage.parse(files(manifest(extra: {'schema': 2}))),
        rejects('schema'),
      );
      expect(() => AicovePackage.parse(const {}), rejects('缺少'));
    });
  });

  test(
    'request policy strips the tags and tool pairs of an inactive package',
    () {
      final provider = AicovePackage.parse(
        files(manifest()),
      ).contentTagProvider(readSkillTool: 'read_skill_demo');
      final messages = [
        {
          'role': 'assistant',
          'content': '好<mood>开心</mood><secret>x</secret>',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'read_skill_demo', 'arguments': '{}'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'c1',
          'name': 'read_skill_demo',
          'content': '押韵',
        },
      ];
      List<Map<String, dynamic>> filter(Set<String> active) =>
          ChatPluginContextPolicy.firstParty(
            activeProviderIds: active,
            extraProviders: [provider],
          ).filterMessages(messages);

      final on = filter({'pkg:demo'});
      expect(on, hasLength(2));
      expect(on.first['content'], '好<mood>开心</mood><secret>x</secret>');

      final off = filter({});
      expect(off.single['content'], '好');
      expect(off.single.containsKey('tool_calls'), isFalse);
    },
  );

  group('store', () {
    late Directory root;
    late PackageStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('packages_');
      store = PackageStore(Directory('${root.path}/packages'));
    });
    tearDown(() => root.delete(recursive: true));

    test('imports a zip with one top folder, lists and deletes it', () async {
      final archive = Archive();
      void add(String name, String text) {
        final bytes = utf8.encode(text);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('demo/${AicovePackage.manifestName}', jsonEncode(manifest()));
      add('demo/skills/guide.md', '# 指南');
      add('__MACOSX/demo/._aicove-package.json', 'meta');
      add('demo/.DS_Store', 'meta');
      final package = await store.importZip(ZipEncoder().encode(archive)!);

      expect(package.id, 'demo');
      expect(
        File('${store.root.path}/demo/skills/guide.md').existsSync(),
        isTrue,
      );
      expect([for (final p in await store.list()) p.id], ['demo']);

      await store.delete('demo');
      expect(await store.list(), isEmpty);
    });

    test(
      'writes nothing for an invalid package and keeps the old one',
      () async {
        await store.importFiles(files(manifest()));
        await expectLater(
          store.importFiles(files(manifest(extra: {'exec': true}))),
          throwsA(isA<PackageFormatException>()),
        );
        expect((await store.list()).single.prompts, ['说话时带一点诗意。']);
      },
    );

    test('re-import replaces the installed copy', () async {
      final dir = Directory('${root.path}/src/skills')
        ..createSync(recursive: true);
      File('${dir.path}/guide.md').writeAsStringSync('旧');
      File(
        '${root.path}/src/${AicovePackage.manifestName}',
      ).writeAsStringSync(jsonEncode(manifest()));
      await store.importDirectory(Directory('${root.path}/src'));
      File('${dir.path}/guide.md').writeAsStringSync('新');
      await store.importDirectory(Directory('${root.path}/src'));
      expect((await store.list()).single.skills.single.content, '新');
    });

    test('delete cannot leave the package root', () async {
      for (final id in ['../x', '..', '.', 'a/b', '']) {
        await expectLater(store.delete(id), throwsArgumentError, reason: id);
      }
    });

    Directory writeSource() {
      final src = Directory('${root.path}/src')..createSync(recursive: true);
      File('${src.path}/${AicovePackage.manifestName}')
          .writeAsStringSync(jsonEncode(manifest()));
      return src;
    }

    test('a linked file pointing outside the folder is rejected', () async {
      final secret = File('${root.path}/secret.txt')
        ..writeAsStringSync('OUTSIDE PRIVATE CONTENT');
      final src = writeSource();
      Directory('${src.path}/skills').createSync();
      Link('${src.path}/skills/guide.md').createSync(secret.path);

      await expectLater(
        store.importDirectory(src),
        throwsA(isA<PackageFormatException>()
            .having((e) => e.message, 'message', contains('链接'))),
      );
      expect(await store.list(), isEmpty);
    });

    test('a linked folder is rejected too', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      File('${outside.path}/guide.md').writeAsStringSync('OUTSIDE');
      final src = writeSource();
      Link('${src.path}/skills').createSync(outside.path);

      await expectLater(
        store.importDirectory(src),
        throwsA(isA<PackageFormatException>()),
      );
    });

    test('a zip with duplicate entry names is rejected', () async {
      // Archive.addFile collapses duplicates, so stream raw entries.
      final out = OutputStream();
      final encoder = ZipEncoder()..startEncode(out);
      void add(String name, String text) {
        final bytes = utf8.encode(text);
        encoder.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add(AicovePackage.manifestName, jsonEncode(manifest()));
      add('skills/guide.md', 'FIRST');
      add('skills/guide.md', 'LAST');
      encoder.endEncode();

      await expectLater(
        store.importZip(out.getBytes()),
        throwsA(isA<PackageFormatException>()
            .having((e) => e.message, 'message', contains('重名'))),
      );
    });

    test('a zip whose content inflates past the budget is rejected', () async {
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add(AicovePackage.manifestName, utf8.encode(jsonEncode(manifest())));
      add('skills/guide.md',
          List<int>.filled(PackageStore.maxPackageBytes + 1, 0x61));
      final zip = ZipEncoder().encode(archive)!;
      expect(zip.length, lessThan(100 * 1024)); // highly compressible

      await expectLater(
        store.importZip(zip),
        throwsA(isA<PackageFormatException>()
            .having((e) => e.message, 'message', contains('2 MB'))),
      );
    });

    test('delete also drops a copy left aside by an interrupted replacement; '
        'unrelated hidden folders stay', () async {
      await store.importFiles(files(manifest()));
      Directory('${store.root.path}/demo')
          .renameSync('${store.root.path}/.demo.123.old');
      final unrelated = Directory('${store.root.path}/.demo.notes.keep')
        ..createSync();

      await store.delete('demo');

      expect(await store.list(), isEmpty);
      expect(unrelated.existsSync(), isTrue);
    });

    test('the size and file budgets stop reading early', () async {
      final big = List<int>.filled(PackageStore.maxPackageBytes + 1, 0x61);
      await expectLater(
        store.importFiles({...files(manifest()), 'skills/big.md': big}),
        throwsA(isA<PackageFormatException>()
            .having((e) => e.message, 'message', contains('2 MB'))),
      );

      final src = writeSource();
      for (var i = 0; i <= PackageStore.maxPackageFiles; i++) {
        File('${src.path}/n$i.md').writeAsStringSync('x');
      }
      await expectLater(
        store.importDirectory(src),
        throwsA(isA<PackageFormatException>()
            .having((e) => e.message, 'message', contains('200'))),
      );
    });

    test('concurrent imports of one package both finish', () async {
      final results = await Future.wait([
        store.importFiles(files(manifest(), others: {'skills/guide.md': 'A'})),
        store.importFiles(files(manifest(), others: {'skills/guide.md': 'B'})),
      ]);
      expect(results, hasLength(2));
      expect((await store.list()).single.skills.single.content, 'B');
      expect(
        store.root.listSync().map((e) => e.uri.pathSegments.lastWhere(
              (part) => part.isNotEmpty,
            )),
        ['demo'],
      );
    });

    test('a replacement interrupted after moving the old copy aside is undone',
        () async {
      await store.importFiles(files(manifest()));
      // Crash between "move old aside" and "move new in".
      Directory('${store.root.path}/demo')
          .renameSync('${store.root.path}/.demo.123.old');
      Directory('${store.root.path}/.demo.124.new').createSync();

      expect([for (final p in await store.list()) p.id], ['demo']);
      expect(Directory('${store.root.path}/.demo.124.new').existsSync(), isFalse);
    });
  });
}
