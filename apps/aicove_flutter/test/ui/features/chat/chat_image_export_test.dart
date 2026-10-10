import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/ui/features/chat/pages/chat_image_export_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_image_export.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

Message _text(String id, String role) => Message(
  id: id,
  role: role,
  content: '$id 的内容',
  createdAt: DateTime(2026, 10, 9),
);

void main() {
  test('同一侧连续气泡只在第一条显示头像', () {
    final grouped = groupChatExportBubbles([
      _text('a_chunk_0', 'assistant'),
      _text('a_chunk_1', 'assistant'),
      _text('u1', 'user'),
      _text('u2', 'user'),
      _text('b', 'assistant'),
    ]);
    expect(grouped.map((b) => b.showAvatar), [true, false, true, false, true]);
    expect(grouped.map((b) => b.showCorner), [true, false, true, false, false]);
  });

  testWidgets('长图带顶栏和输入框、按屏高循环背景、包含真实图片像素', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(historyCount: 20),
    ))!;
    final redPng = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 100, 100),
        Paint()..color = const Color(0xFFFF0000),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 100);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }))!;
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
            base64: base64Encode(redPng),
            width: 100,
            height: 100,
          ),
        ],
      ),
    ];
    // One screen: green on top, blue below, so repeats are visible.
    const tile = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: ColoredBox(color: Color(0xFF00FF00))),
        Expanded(child: ColoredBox(color: Color(0xFF0000FF))),
      ],
    );
    const screenHeight = 600.0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: ChatImageExportPage(
            messages: messages,
            title: '长图导出验收',
            background: tile,
            chatSize: const Size(400, screenHeight),
          ),
        ),
      ),
    );
    for (var i = 0; i < 200 && find.text('保存图片').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('保存图片'), findsOneWidget, reason: '图片全部解码后才能保存');
    expect(find.byType(MoeChatHeader), findsOneWidget);
    expect(find.byType(ComposerIdlePreview), findsOneWidget);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find
          .ancestor(
            of: find.byType(ChatExportCanvas),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    await tester.runAsync(() async {
      final bytes = await captureChatExportImage(boundary, pixelRatio: 1);
      const evidence = String.fromEnvironment('CHAT_EXPORT_EVIDENCE');
      if (evidence.isNotEmpty) await File(evidence).writeAsBytes(bytes);
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 400);
      expect(image.height, greaterThan(screenHeight * 2), reason: '包含屏幕外消息');
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      List<int> pixel(int x, int y) {
        final i = (y * image.width + x) * 4;
        return rgba.sublist(i, i + 3);
      }

      bool greenish(List<int> p) => p[1] > p[0] + 60 && p[1] > p[2] + 60;
      bool bluish(List<int> p) => p[2] > p[0] + 60 && p[2] > p[1] + 60;
      // Left edge rows clear of header, bubbles and composer.
      final secondTileTop = screenHeight.toInt() + 150;
      final secondTileBottom = screenHeight.toInt() * 2 - 150;
      expect(greenish(pixel(1, secondTileTop)), isTrue, reason: '第二屏背景重新开始');
      expect(bluish(pixel(1, secondTileBottom)), isTrue);
      var redPixels = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        if (rgba[i] > 240 && rgba[i + 1] < 10 && rgba[i + 2] < 10) redPixels++;
      }
      expect(redPixels, greaterThan(5000), reason: '图片完成解码后才导出');
      image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.dispose);
  });
}
