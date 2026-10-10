import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/chat/pages/chat_image_export_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_image_export.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_wallpaper_background.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

Future<ui.Image> wallpaper() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 100),
    Paint()..color = const Color(0xFFBCD9CF),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 100, 100, 100),
    Paint()..color = const Color(0xFFE6D3B0),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 200);
  picture.dispose();
  return image;
}

void main() {
  const output = String.fromEnvironment('SHARE_PREVIEW_DIR');
  setUpAll(() async {
    if (output.isEmpty) return;
    for (final entry in {
      'ExportPreview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  testWidgets('长图沿用聊天背景并按屏高循环，预览在固定标题与保存按钮之间滚动', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(historyCount: 24),
    ))!;
    final png = (await tester.runAsync(() async {
      final tile = await wallpaper();
      final bytes = (await tile.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      tile.dispose();
      return bytes;
    }))!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: RepaintBoundary(
          key: const ValueKey('export-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: output.isEmpty ? null : 'ExportPreview',
              extensions: [MoeColors.light()],
            ),
            home: ChatImageExportPage(
              messages: fixture.conversation.messages,
              title: '与小林的聊天',
              background: ChatWallpaperLayer(
                image: 'data:image/png;base64,${base64Encode(png)}',
                fallbackColor: Colors.white,
                maskOpacity: 0.2,
              ),
              chatSize: const Size(390, 800),
            ),
          ),
        ),
      ),
    );
    final save = find.byKey(const ValueKey('chat-export-save'));
    for (var i = 0; i < 200 && find.text('保存图片').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('保存图片'), findsOneWidget);
    final preview = find.byKey(const ValueKey('chat-export-preview'));
    final scroll = find.byKey(const ValueKey('chat-export-scroll'));
    final header = find.text('导出图片');
    expect(tester.getRect(header).bottom, lessThan(tester.getRect(scroll).top));
    expect(tester.getRect(save).top, greaterThanOrEqualTo(tester.getRect(scroll).bottom));
    expect(tester.getRect(preview).height, greaterThan(1200));
    Future<void> capture(String name) async {
      if (output.isEmpty) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('export-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('export-page');
    final canvas = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: preview, matching: find.byType(RepaintBoundary)).first,
    );
    await tester.runAsync(() async {
      final bytes = await captureChatExportImage(canvas, pixelRatio: 2);
      if (output.isNotEmpty) {
        await File('$output/export-long.png').writeAsBytes(bytes);
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      List<int> pixel(int y) =>
          rgba.sublist(y * image.width * 4, y * image.width * 4 + 4);
      expect(image.width, 780);
      expect(pixel(300), pixel(1900), reason: '每张背景占聊天页一屏，2倍像素比下高1600像素');
      expect(pixel(300), isNot([255, 255, 255, 255]));
      image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.dispose);
  });
}
