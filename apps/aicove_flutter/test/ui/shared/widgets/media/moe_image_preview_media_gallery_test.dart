import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/media/moe_image_preview.dart';

void main() {
  testWidgets('画廊可从普通图片滑到共享媒体库里的图片', (tester) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    late Directory root;
    late MediaStore store;
    late File plainFile;
    late String mediaReference;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('media-gallery-');
      store = MediaStore(Directory('${root.path}/store'), 'device');
      final picture = img.Image(width: 40, height: 30);
      plainFile = File('${root.path}/plain.png')
        ..writeAsBytesSync(img.encodePng(picture));
      final mediaFile = File('${root.path}/media.png')
        ..writeAsBytesSync(img.encodePng(picture));
      final record = await store.register(
        mediaFile.path,
        createdAtMs: 1,
        mimeType: 'image/png',
      );
      mediaReference = record.asset.reference;
      MediaStore.use(store);
    });
    addTearDown(() async {
      await store.close();
      await root.delete(recursive: true);
    });

    final images = collectChatMessageListImages([
      Message.fromBlocks(
        id: 'm1',
        role: 'assistant',
        blocks: [
          ImageBlock(id: 'plain', messageId: 'm1', localPath: plainFile.path),
          ImageBlock(id: 'media', messageId: 'm1', localPath: mediaReference),
        ],
      ),
    ]);
    expect(images.map((item) => item.heroTag), ['image_plain', 'image_media']);
    expect(images.last.mediaId, isNotNull);
    expect(images.last.provider, isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                MoeImagePreview.showGallery(context, images: images),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final page = tester.widget<PageView>(find.byType(PageView));
    expect(page.controller!.page, 1);

    for (var i = 0; i < 40; i++) {
      final shown = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<FileImage>()
          .any((provider) => provider.file.path != plainFile.path);
      if (shown) break;
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      });
      await tester.pump();
    }
    expect(
      tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<FileImage>()
          .any((provider) => provider.file.path != plainFile.path),
      isTrue,
    );
  });
}
