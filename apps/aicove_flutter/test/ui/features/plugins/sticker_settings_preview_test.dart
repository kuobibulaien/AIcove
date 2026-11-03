@Tags(['preview'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/stickers/sticker_library.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_library_provider.dart';
import 'package:aicove_flutter/src/features/stickers/sticker_registry.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/sticker_pack_page.dart';
import 'package:aicove_flutter/src/ui/features/plugins/pages/sticker_settings_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表情包设置页与套组页的源码渲染预览。
///
/// 常规运行只做轻量 smoke；带 `--dart-define=WRITE_STICKER_QA=true`
/// 时把页面渲染成 PNG 写入 `scratch/sticker-settings/`。
void main() {
  const capture = bool.fromEnvironment('WRITE_STICKER_QA');
  late Directory root;
  late StickerLibrary library;
  late String importedPackId;

  setUpAll(() async {
    // 用临时目录里的真实库：一个导入套组（含一张未标注）。
    root = await Directory.systemTemp.createTemp('sticker_preview');
    library = StickerLibrary(root);
    await library.load();
    Uint8List asset(String name) =>
        File('assets/stickers/builtin/$name.webp').readAsBytesSync();
    final result = await library.importFiles([
      StickerImportFile('贴贴.webp', asset('xiaokumao/459a6ca140046c4119aea0c038a3f742')),
      StickerImportFile('得意 叉腰.webp', asset('zhegou/f4703a3fe296d0c814eec32e4c97dbbc')),
      StickerImportFile('摸鱼-2.webp', asset('xiaokumao/b2cb23f85dc95dc1b610cc928da19243')),
      StickerImportFile('IMG_0412.webp', asset('xiaokumao/dd3af701f8252f061f86bcb319aeeb1a')),
    ], packName: '猫猫日常', author: '示例作者');
    importedPackId = result.packIds.single;
    StickerLibraryNotifier.open = () async => library;

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

  tearDownAll(() async {
    StickerRegistry.instance.replaceStickers(const []);
    await root.delete(recursive: true);
  });

  // 文件图片的读取与解码要真实异步，多轮让出后再截图。
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  }

  Future<GlobalKey> pumpPage(
    WidgetTester tester,
    Widget page, {
    double width = 390,
    bool dark = false,
  }) async {
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
          builder: (context, child) => RepaintBoundary(key: key, child: child!),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await settleImages(tester);
    return key;
  }

  testWidgets('pack list renders at phone and detail widths', (tester) async {
    addTearDown(tester.view.reset);
    for (final width in [390.0, 760.0]) {
      for (final dark in [false, true]) {
        final key = await pumpPage(
          tester,
          const StickerSettingsPage(),
          width: width,
          dark: dark,
        );
        expect(find.text('猫猫日常'), findsOneWidget);
        expect(find.text('4 张 · 示例作者 · 1 张未标注'), findsOneWidget);
        expect(find.text('纳西妲（内置）'), findsNothing);
        expect(
          find.text('所有表情包来源于微信公众号公开表情，已标注原作者，如有侵权请联系删除。'),
          findsOneWidget,
        );
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

  testWidgets('search finds imported stickers by synonym', (tester) async {
    addTearDown(tester.view.reset);
    await pumpPage(tester, const StickerSettingsPage());
    await tester.enterText(find.byType(TextField), '抱抱');
    await tester.pumpAndSettle();
    expect(find.text('搜索结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pack page groups untagged and opens editable detail', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final key = await pumpPage(tester, StickerPackPage(packId: importedPackId));
    expect(find.text('未标注'), findsOneWidget);
    expect(find.text('让 AI 使用这个套组'), findsOneWidget);
    expect(find.text('示例作者'), findsOneWidget);
    if (capture) {
      await _capture(
        tester,
        key,
        '../../scratch/sticker-settings/light-390-pack.png',
      );
    }

    await tester.tap(find.byType(Image).at(1));
    await tester.pumpAndSettle();
    await settleImages(tester);
    expect(find.text('删除这张表情'), findsOneWidget);
    if (capture) {
      await _capture(
        tester,
        key,
        '../../scratch/sticker-settings/light-390-sheet.png',
      );
    }

    // 点开「标签」编辑，防抖自动保存时不应中途把编辑框关掉，关闭后详情页与库同步刷新
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    expect(find.text('编辑标签'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '贴贴，撒娇');
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    expect(find.text('编辑标签'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('编辑标签'), findsNothing);
    expect(find.text('贴贴、撒娇'), findsOneWidget);

    // 再次点开编辑时应带出最新保存的标签，还原初始值以免影响其他用例
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller?.text, '贴贴，撒娇');
    await tester.enterText(find.byType(TextField).last, '贴贴');
    await tester.pump(const Duration(milliseconds: 500));
    await settleImages(tester);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
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
