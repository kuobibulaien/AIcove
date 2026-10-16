import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 源码渲染预览：新增内置壁纸「灯湖」在全局壁纸选择格里的样子，以及它作为
/// 页面底色时的整屏效果（浅色／深色各一张）。
/// `--dart-define=WRITE_WALLPAPER_PREVIEW=true` 时写到 scratch/wallpaper-laketown/。
void main() {
  const capture = bool.fromEnvironment('WRITE_WALLPAPER_PREVIEW');
  const outDir = '../../scratch/wallpaper-laketown';

  setUpAll(() async {
    if (!capture) return;
    for (final entry in {
      'WallpaperPreview': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/'
              'artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        File(entry.value).readAsBytes().then(ByteData.sublistView),
      );
      await loader.load();
    }
  });

  /// 测试环境默认不解码真实图片，先把用到的资源图解码进缓存再截图。
  Future<void> precacheWallpapers(WidgetTester tester, BuildContext context) =>
      tester.runAsync(() async {
        for (final wallpaper in GlobalWallpaper.values) {
          for (final brightness in Brightness.values) {
            final asset = wallpaper.assetFor(
              GlobalWallpaperSlot.page,
              brightness,
            );
            if (asset == null) continue;
            await precacheImage(AssetImage(asset), context);
          }
        }
      });

  Future<void> captureTo(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory(outDir)..createSync(recursive: true);
      await File('${dir.path}/$name.png').writeAsBytes(
        bytes!.buffer.asUint8List(),
      );
      image.dispose();
    });
  }

  /// 壁纸选择格：与 UiSettingsPage 的 `_buildWallpaperTile` 同一套尺寸与外观。
  Widget tile(
    GlobalWallpaper wallpaper,
    Brightness brightness, {
    bool selected = false,
  }) {
    const box = 64.0;
    return Container(
      height: box,
      width: box,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? const Color(0xFF7A6BD6) : const Color(0x33FFFFFF),
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          wallpaper.assetFor(GlobalWallpaperSlot.empty, brightness)!,
          fit: BoxFit.cover,
          alignment: wallpaper.alignment,
        ),
      ),
    );
  }

  for (final dark in [false, true]) {
    testWidgets('laketown wallpaper preview dark=$dark', (tester) async {
      if (!capture) return;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 900);
      addTearDown(tester.view.reset);
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      final brightness = dark ? Brightness.dark : Brightness.light;
      final key = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            fontFamily: 'WallpaperPreview',
            extensions: [colors],
          ),
          home: RepaintBoundary(
            key: key,
            child: MoeWallpaperTheme(
              wallpaper: GlobalWallpaper.laketown,
              child: MoePageScaffold(
                body: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '全局壁纸',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          for (final wallpaper in GlobalWallpaper.values)
                            if (wallpaper != GlobalWallpaper.custom)
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Column(
                                  children: [
                                    if (wallpaper == GlobalWallpaper.laketown)
                                      tile(wallpaper, brightness, selected: true)
                                    else if (wallpaper == GlobalWallpaper.none)
                                      Container(
                                        height: 64,
                                        width: 64,
                                        decoration: BoxDecoration(
                                          color: colors.surface,
                                          border: Border.all(
                                            color: const Color(0x33FFFFFF),
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          Icons.block_rounded,
                                          color: colors.textSecondary,
                                        ),
                                      )
                                    else
                                      tile(wallpaper, brightness),
                                    const SizedBox(height: 6),
                                    Text(
                                      wallpaper.label,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: wallpaper ==
                                                GlobalWallpaper.laketown
                                            ? colors.primary
                                            : colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: MoeFloatingSurface(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '壁纸作为页面底色',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: colors.text,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '未自定义背景的界面共用这一张，跟随主题在浅色／深色两版之间自动切换。',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await precacheWallpapers(tester, key.currentContext!);
      await tester.pumpAndSettle();
      await captureTo(tester, key, 'settings-${dark ? 'dark' : 'light'}');

      // 整屏纯壁纸（窄屏比例），看竖屏裁切后的观感。
      final fullKey = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: brightness,
            extensions: [colors],
          ),
          home: RepaintBoundary(
            key: fullKey,
            child: const MoeWallpaperTheme(
              wallpaper: GlobalWallpaper.laketown,
              child: MoePageScaffold(body: SizedBox.expand()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await precacheWallpapers(tester, fullKey.currentContext!);
      await tester.pumpAndSettle();
      await captureTo(tester, fullKey, 'narrow-${dark ? 'dark' : 'light'}');
    });
  }
}
