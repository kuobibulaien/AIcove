import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_image_export.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  testWidgets('完整长图包含视口外文字和真实图片像素', (tester) async {
    final fixture = (await tester
        .runAsync(() => SegmentedChatFixture.create(historyCount: 20)))!;
    late BuildContext renderContext;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: Scaffold(body: Builder(builder: (context) {
          renderContext = context;
          return const SizedBox.shrink();
        })),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = const Color(0xFFFF0000));
      final picture = recorder.endRecording();
      final red = await picture.toImage(100, 100);
      final redData = await red.toByteData(format: ui.ImageByteFormat.png);
      expect((await red.toByteData())!.buffer.asUint8List().take(4),
          [255, 0, 0, 255]);
      red.dispose();
      picture.dispose();
      final messages = [
        ...fixture.conversation.messages,
        Message(
          id: 'red-image',
          role: 'assistant',
          content: '',
          createdAt: DateTime.now(),
          blocks: [
            ImageBlock(
                id: 'red',
                messageId: 'red-image',
                base64: base64Encode(redData!.buffer.asUint8List()),
                width: 100,
                height: 100)
          ],
        ),
      ];
      final bytes = await renderChatImage(
          context: renderContext,
          messages: messages,
          title: '长图导出验收',
          background: telegramChatBackground);
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 840);
      expect(image.height, greaterThan(1600), reason: '包含屏幕外消息而非可视区截图');
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      var redPixels = 0;
      for (var i = image.width * (image.height * .7).floor() * 4;
          i < rgba.length;
          i += 4) {
        if (rgba[i] > 240 && rgba[i + 1] < 10 && rgba[i + 2] < 10) redPixels++;
      }
      const evidence = String.fromEnvironment('CHAT_EXPORT_EVIDENCE');
      if (evidence.isNotEmpty) await File(evidence).writeAsBytes(bytes);
      expect(redPixels, greaterThan(10000), reason: '图片完成解码、缩放后才导出');
      image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.dispose);
  });
}
