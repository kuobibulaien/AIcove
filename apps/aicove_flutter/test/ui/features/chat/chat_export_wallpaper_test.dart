import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/chat/pages/chat_image_export_page.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_image_export.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_export_wallpaper.dart';
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

  testWidgets('背景等比逐张接续，末张裁切而不拉伸', (tester) async {
    await tester.runAsync(() async {
      final tile = await wallpaper();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      ChatExportWallpaperPainter(
        image: tile,
        background: Colors.white,
        maskOpacity: 0.4,
        blurSigma: 0,
      ).paint(canvas, const Size(100, 450));
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 450);
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      List<int> pixel(int y) =>
          rgba.sublist((y * 100 + 1) * 4, (y * 100 + 2) * 4);
      expect(pixel(25), pixel(225));
      expect(pixel(25), pixel(425));
      expect(pixel(149), pixel(349));
      expect(pixel(49), pixel(449), reason: '最后一张只绘制前50px');
      expect(pixel(25), isNot(pixel(149)));
      image.dispose();
      picture.dispose();
      tile.dispose();
    });
  });

  testWidgets('长图使用当前背景，预览头尾控件随图片滚动', (tester) async {
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
    late BuildContext host;
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
            home: Builder(
              builder: (context) {
                host = context;
                return ChatImageExportPage(
                  messages: fixture.conversation.messages,
                  title: '与小林的聊天',
                  background: Colors.white,
                  wallpaper: MemoryImage(png),
                  wallpaperMaskOpacity: 0.2,
                );
              },
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (find
          .byKey(const ValueKey('chat-export-preview'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    await tester.pumpAndSettle();
    final preview = find.byKey(const ValueKey('chat-export-preview'));
    expect(preview, findsOneWidget);
    final imageRect = tester.getRect(preview);
    final header = find.text('导出图片');
    final save = find.byKey(const ValueKey('chat-export-save'));
    expect(tester.getRect(header).bottom, lessThan(imageRect.top));
    expect(tester.getRect(save).top, greaterThanOrEqualTo(imageRect.bottom));
    expect(imageRect.height, greaterThan(800));
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

    await capture('export-head');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    expect(tester.getRect(header).bottom, lessThan(0));
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(800));
    await capture('export-tail');
    await tester.runAsync(() async {
      final bytes = await renderChatImage(
        context: host,
        messages: fixture.conversation.messages,
        title: '与小林的聊天',
        background: Colors.white,
        wallpaper: MemoryImage(png),
        wallpaperMaskOpacity: 0.2,
      );
      if (output.isNotEmpty) {
        await File('$output/export-long.png').writeAsBytes(bytes);
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final rgba = (await image.toByteData())!.buffer.asUint8List();
      List<int> pixel(int y) =>
          rgba.sublist(y * image.width * 4, y * image.width * 4 + 4);
      expect(pixel(100), pixel(1780), reason: '420逻辑宽、2倍像素比，每张背景高1680像素');
      expect(pixel(100), isNot([255, 255, 255, 255]));
      image.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(fixture.dispose);
  });
}
