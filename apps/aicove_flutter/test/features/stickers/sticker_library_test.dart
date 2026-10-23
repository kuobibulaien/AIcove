import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/plugins/sticker/sticker_config.dart';
import 'package:aicove_flutter/src/features/plugins/sticker/sticker_plugin.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Uint8List _png(int seed) => Uint8List.fromList(
  img.encodePng(img.Image(width: 4, height: 4)..setPixelRgb(0, 0, seed, 0, 0)),
);

void main() {
  late Directory root;
  late StickerLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker_library_test');
    library = StickerLibrary(root);
    await library.load();
  });

  tearDown(() async {
    StickerRegistry.instance.replaceStickers(const []);
    await root.delete(recursive: true);
  });

  group('stickerLabelFromFileName', () {
    test('uses file name as tags and strips numeric suffix', () {
      expect(stickerLabelFromFileName('开心-2.png').tags, ['开心']);
      expect(stickerLabelFromFileName('猫猫 摇尾巴(3).gif').tags, ['猫猫', '摇尾巴']);
      expect(stickerLabelFromFileName('晚安_01.webp').description, '晚安');
    });

    test('generic camera or chat-app names stay untagged', () {
      for (final name in ['IMG_1234.jpg', '微信图片_20260101.png', '123.png']) {
        expect(stickerLabelFromFileName(name).tags, isEmpty, reason: name);
      }
    });
  });

  test('imports images into a new pack and exposes them to AI', () async {
    final result = await library.importFiles([
      StickerImportFile('贴贴.png', _png(1)),
      StickerImportFile('IMG_0001.png', _png(2)),
      StickerImportFile('不是图片.txt', Uint8List.fromList([1, 2, 3])),
      StickerImportFile('贴贴-2.png', _png(1)), // 同一张图重复
    ], packName: '小猫');

    expect(result.added, 2);
    expect(result.untagged, 1);
    expect(result.skipped, 2);
    final pack = library.packById(result.packIds.single)!;
    expect(pack.name, '小猫');
    expect(pack.untaggedCount, 1);
    expect(File(pack.stickers.first.path).existsSync(), isTrue);

    // 「贴贴」与内置「抱抱」同义，导入后同组候选里包含新表情
    final candidates = StickerRegistry.instance.getAllByTag('贴贴');
    expect(candidates.any((s) => s.packId == pack.id), isTrue);
  });

  test('library survives reload and pack toggle controls the registry', () async {
    final result = await library.importFiles([
      StickerImportFile('摸摸头.png', _png(3)),
    ]);
    final packId = result.packIds.single;

    final reloaded = StickerLibrary(root);
    await reloaded.load();
    expect(reloaded.packById(packId)!.stickers.single.tags, ['摸摸头']);
    expect(StickerRegistry.instance.hasTag('摸摸头'), isTrue);

    await reloaded.setPackEnabled(packId, false);
    expect(StickerRegistry.instance.hasTag('摸摸头'), isFalse);
    expect(StickerRegistry.instance.stickers, isEmpty);
  });

  test('zip import creates one pack per top-level folder', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('猫猫/开心.png', 0, _png(4)))
      ..addFile(ArchiveFile('猫猫/难过.png', 0, _png(5)))
      ..addFile(ArchiveFile('狗狗/汪.png', 0, _png(6)))
      ..addFile(ArchiveFile('__MACOSX/猫猫/._开心.png', 0, _png(7)));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final result = await library.importZip(bytes, 'pets.zip');

    expect(result.added, 3);
    final names = {for (final id in result.packIds) library.packById(id)!.name};
    expect(names, {'猫猫', '狗狗'});
  });

  test('editing tags re-indexes; deleting keeps files of sent stickers', () async {
    final result = await library.importFiles([
      StickerImportFile('IMG_1.png', _png(8)),
      StickerImportFile('IMG_2.png', _png(9)),
    ]);
    final pack = library.packById(result.packIds.single)!;
    final sent = pack.stickers[0];
    final unsent = pack.stickers[1];

    await library.updateSticker(sent.id, tags: ['[得意]', '得意', ' ']);
    expect(StickerRegistry.instance.getByTag('得意')!.id, sent.id);

    await library.markUsed(sent.id);
    await library.deletePack(pack.id);

    expect(library.packById(pack.id), isNull);
    expect(File(sent.path).existsSync(), isTrue, reason: '历史消息仍引用');
    expect(File(unsent.path).existsSync(), isFalse);
    expect(StickerRegistry.instance.hasTag('得意'), isFalse);
  });

  test('zip import applies labels.json tags, description and pack name', () async {
    final labels = {
      'name': '猫猫·动图',
      'author': '猫猫作者',
      'stickers': {
        'a.png': {
          'tags': ['委屈', '撒娇'],
          'description': '哄我',
        },
      },
    };
    final archive = Archive()
      ..addFile(ArchiveFile('猫猫/a.png', 0, _png(8)))
      ..addFile(ArchiveFile('猫猫/开心.png', 0, _png(9)))
      ..addFile(
        ArchiveFile.string('猫猫/labels.json', jsonEncode(labels)),
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final result = await library.importZip(bytes, 'pets.zip');

    expect(result.added, 2);
    expect(result.skipped, 0);
    final pack = library.packById(result.packIds.single)!;
    expect(pack.name, '猫猫·动图');
    expect(pack.author, '猫猫作者');
    // 清单里有的按清单标注，没有的仍按文件名推断
    expect(pack.stickers.map((s) => s.tags), [
      ['委屈', '撒娇'],
      ['开心'],
    ]);
    expect(pack.stickers.first.description, '哄我');
  });

  test('built-in packs are seeded once with labels and survive reload', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await library.seedBuiltin(rootBundle);

    expect(library.packs.map((p) => p.name).toSet(), {
      'YoMee企鹅',
      '呆猫八条与淑熊',
      '小哭猫',
      '这狗',
      '鱼烧哥',
    });
    final stickers = [for (final p in library.packs) ...p.stickers];
    expect(stickers, hasLength(291));
    expect(stickers.where((s) => s.tags.isEmpty), isEmpty);
    expect(library.packs.firstWhere((p) => p.name == '这狗').author, '这狗ZOGGY');
    expect(StickerRegistry.instance.hasTag('撒娇'), isTrue);

    // 用户删掉一个内置套组后，重新加载不会再放回来
    await library.deletePack(library.packs.first.id);
    final reloaded = StickerLibrary(root);
    await reloaded.load();
    await reloaded.seedBuiltin(rootBundle);
    expect(reloaded.packs, hasLength(4));
    expect(reloaded.packs.every((p) => p.author.isNotEmpty), isTrue);
  });

  test('库里没有内置套组，旧清单里的内置条目读取时忽略', () async {
    expect(library.packs, isEmpty);

    await root.create(recursive: true);
    await File(p.join(root.path, 'library.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'usedIds': <String>[],
        'packs': [
          {'id': 'builtin_nahida', 'builtin': true, 'enabled': true},
        ],
      }),
    );
    final reloaded = StickerLibrary(root);
    await reloaded.load();
    expect(reloaded.packs, isEmpty);
    expect(StickerRegistry.instance.stickers, isEmpty);
  });

  test('plugin converts an imported sticker tag into a sticker event', () async {
    await library.importFiles([StickerImportFile('比心.png', _png(11))]);
    final plugin = StickerPlugin(const StickerConfig());

    final prompt = await plugin.buildSystemPrompt();
    expect(prompt, contains('比心'));

    final processed = await plugin.convertStickerTags('爱你哦 <sticker tag="比心"/>');
    expect(processed.processedText, '爱你哦');
    final event = processed.events.single;
    expect(event.type, 'sticker_convert');
    expect(event.data['assetPath'], startsWith(root.path));
  });
}
