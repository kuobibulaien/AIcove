import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late StickerLibrary library;
  late String current;
  late String stickerId;
  late String stale;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker_local_projection');
    library = StickerLibrary(Directory(p.join(root.path, 'stickers')));
    await library.load();
    final imported = await library.importFiles([
      StickerImportFile('晚安.png', Uint8List.fromList([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1,
      ])),
    ]);
    final pack = library.packById(imported.packIds.single)!;
    current = pack.stickers.single.path;
    stickerId = pack.stickers.single.id;
    stale = '/old-device/stickers/files/${p.basename(current)}';
    await library.setPackEnabled(pack.id, false);
  });

  tearDown(() async => root.delete(recursive: true));

  test('resolves strict content filenames or exact IDs across disabled packs', () {
    expect(StickerLibrary.resolveLocalPath(stale), current);
    expect(StickerLibrary.resolveLocalPath(r'C:\old\stickers\files\' + p.basename(current)), current);
    expect(StickerLibrary.resolveLocalPath('/missing/old.png', stickerId: stickerId), current);
    expect(StickerLibrary.resolveLocalPath('/missing/old.png', stickerId: '晚安'), '/missing/old.png');
    for (final path in [
      '/old/files/${p.basename(current)}',
      '/old/stickers/files/${p.basename(current).toUpperCase()}',
      '/old/stickers/files/${p.basename(current)}.bak',
      '/old/stickers/files/not-a-content-hash.png',
    ]) {
      expect(StickerLibrary.resolveLocalPath(path), path);
    }
  });

  test('preserves real original files and non-local references even with exact ID', () async {
    final original = await File(p.join(root.path, 'original.png')).writeAsBytes([1]);
    for (final path in [
      original.path,
      'assets/stickers/missing.png',
      'packages/example/stickers/missing.png',
      'aicove-media://asset-id',
      'https://example.com/stickers/files/${p.basename(current)}',
      'http://example.com/image.png',
    ]) {
      expect(StickerLibrary.resolveLocalPath(path, stickerId: stickerId), path);
    }
  });

  test('file URIs prefer readable originals and repair missing local sticker files', () async {
    final original = await File(p.join(root.path, 'original with space.png')).writeAsBytes([1]);
    expect(StickerLibrary.resolveLocalPath(original.uri.toString(), stickerId: stickerId), original.path);
    expect(StickerLibrary.resolveLocalPath(Uri.file(stale).toString()), current);
  });

  test('history content remains resolvable by filename after all pack entries are deleted', () async {
    await library.markUsed(stickerId);
    await library.deletePack(library.packs.single.id);
    await StickerLibrary(library.root).load();
    expect(StickerLibrary.resolveLocalPath(stale), current);
  });

  test('processor construction and segmented sticker data resolve copies only', () {
    final event = PluginEvent(pluginId: 'sticker', type: 'sticker_convert', data: {
      'assetPath': stale, 'stickerId': stickerId, 'tag': '晚安',
    });
    const text = '<sticker tag="晚安"/>';
    final built = const ChatMessageProcessor().buildAssistantMessages(
      replyText: text, processedText: '', pluginEvents: [event],
    );
    expect(built.messages.single.blocks!.single, isA<EmojiBlock>());
    expect((built.messages.single.blocks!.single as EmojiBlock).path, current);
    final segments = const ChatMessageProcessor().parseMultimodalSegments(text, [event]);
    expect(segments.single.stickerData!['assetPath'], current);
    expect(event.data['assetPath'], stale);
  });

  test('legacy sticker plugin events and sticker_convert share attachment semantics', () {
    for (final event in [
      PluginEvent(pluginId: 'sticker', type: 'legacy', data: {
        'assetPath': stale, 'stickerId': stickerId, 'tag': '晚安',
      }),
      PluginEvent(pluginId: 'legacy', type: 'sticker_convert', data: {
        'assetPath': stale, 'stickerId': stickerId, 'tag': '晚安',
      }),
    ]) {
      final built = const ChatMessageProcessor().buildAssistantMessages(
        replyText: '<sticker tag="晚安"/>', processedText: '', pluginEvents: [event],
      );
      expect((built.messages.single.blocks!.single as EmojiBlock).path, current);
      final segments = const ChatMessageProcessor().parseMultimodalSegments(
        '<sticker tag="晚安"/>', [event],
      );
      expect(segments.single.stickerData!['assetPath'], current);
    }
    for (final data in <Map<String, dynamic>>[
      {'tag': '晚安'}, {'tag': '晚安', 'assetPath': ''},
      {'tag': '晚安', 'assetPath': 42},
    ]) {
      final event = PluginEvent(pluginId: 'sticker', type: 'legacy', data: data);
      final built = const ChatMessageProcessor().buildAssistantMessages(
        replyText: '原文<sticker tag="晚安"/>', processedText: '处理后', pluginEvents: [event],
      );
      expect(built.messages.single.displayText, '处理后');
      expect(const ChatMessageProcessor().parseMultimodalSegments(
        '<sticker tag="晚安"/>', [event],
      ), isEmpty);
    }
  });

  test('passthrough and cached projections resolve all roles without mutating raw or manifest', () async {
    final manifest = File(p.join(library.root.path, 'library.json'));
    final before = await manifest.readAsString();
    const service = ChatFrontendMessageProjectionService();
    for (final role in ['user', 'assistant']) {
      final stored = Message.fromBlocks(id: 'stored', role: role, blocks: [
        EmojiBlock(id: 'emoji', messageId: 'stored', emojiId: stickerId,
          path: stale, matchedTag: '晚安', originalText: 'original'),
      ]);
      final raw = Message(id: 'raw', role: role, content: '', createdAt: DateTime(2026),
        rawPayload: {'projectedMessages': ChatMessageProjectionCodec.serializeMessages([stored])});
      for (final projected in [service.projectMessage(stored), service.projectMessage(raw)]) {
        final block = projected.single.blocks!.single as EmojiBlock;
        expect(block.path, current);
        expect(block.emojiId, stickerId);
        expect(block.matchedTag, '晚安');
        expect(block.originalText, 'original');
      }
      expect((stored.blocks!.single as EmojiBlock).path, stale);
      expect(jsonEncode(raw.rawPayload), contains(stale));
    }
    expect(await manifest.readAsString(), before);
  });

  test('chat image provider resolves relocated sticker files and skips cloud media URIs', () {
    final relocatedProvider = resolveChatMessageListImageProvider(
      EmojiBlock(
        id: 'e1',
        messageId: 'm1',
        emojiId: stickerId,
        path: stale,
      ),
    );
    expect(relocatedProvider, isA<FileImage>());
    expect((relocatedProvider! as FileImage).file.path, current);

    final mediaUriProvider = resolveChatMessageListImageProvider(
      EmojiBlock(
        id: 'e2',
        messageId: 'm1',
        emojiId: stickerId,
        path: 'aicove-media://${'a' * 64}',
      ),
    );
    expect(mediaUriProvider, isNull);
  });
}
