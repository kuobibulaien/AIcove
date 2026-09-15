import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/features/plugins/pages/sticker_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表情包设置页的源码渲染预览。
///
/// 常规运行只做轻量 smoke；带 `--dart-define=WRITE_STICKER_QA=true`
/// 时把页面渲染成 PNG 写入 `scratch/sticker-settings/`。
void main() {
  const capture = bool.fromEnvironment('WRITE_STICKER_QA');

  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('StickerPreview')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });

  testWidgets('sticker settings renders at phone and detail widths', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    for (final width in [390.0, 760.0]) {
      for (final dark in [false, true]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        SharedPreferences.setMockInitialValues({});
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            child: MaterialApp(
              theme: ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: dark ? moeAccentDark : const Color(0xFFFC96AA),
                  brightness: dark ? Brightness.dark : Brightness.light,
                  surface: dark ? moeSurfaceDark : moeSurface,
                  onSurface: dark ? moeTextDark : moeText,
                ),
                scaffoldBackgroundColor: dark ? moeSurfaceDark : moeSurface,
                fontFamily: capture ? 'StickerPreview' : null,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
              builder: (context, child) =>
                  RepaintBoundary(key: key, child: child!),
              home: const StickerSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Let real asset decoding finish before capture.
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (capture) {
          await _capture(
            tester,
            key,
            '../../scratch/sticker-settings/'
            '${dark ? 'dark' : 'light'}-${width.toInt()}.png',
          );
        }
      }
    }
  });

  testWidgets('sticker detail sheet preview', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              brightness: Brightness.light,
              surface: moeSurface,
              onSurface: moeText,
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'StickerPreview' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) => RepaintBoundary(key: key, child: child!),
          home: const StickerSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Open the first sticker's detail sheet.
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('来自套组 nahida'), findsOneWidget);
    if (capture) {
      await _capture(
        tester,
        key,
        '../../scratch/sticker-settings/light-390-sheet.png',
      );
    }
  });
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
