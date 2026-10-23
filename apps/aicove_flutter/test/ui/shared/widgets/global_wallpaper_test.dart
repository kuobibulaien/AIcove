import 'dart:io';

import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_wallpaper.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_page_scaffold.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  Widget child, {
  GlobalWallpaper wallpaper = GlobalWallpaper.catnap,
  String? customImagePath,
  WallpaperStyle style = const WallpaperStyle(mask: 0.4),
  bool dark = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      extensions: [dark ? MoeColors.dark() : MoeColors.light()],
    ),
    home: MoeWallpaperTheme(
      wallpaper: wallpaper,
      customImagePath: customImagePath,
      style: style,
      child: child,
    ),
  );
}

Set<String> _assetNames(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .map((image) => image.image)
    .whereType<AssetImage>()
    .map((image) => image.assetName)
    .toSet();

void main() {
  test('every wallpaper set ships all slots in light and dark', () {
    for (final wallpaper in GlobalWallpaper.values) {
      for (final slot in GlobalWallpaperSlot.values) {
        for (final brightness in Brightness.values) {
          final asset = wallpaper.assetFor(slot, brightness);
          if (wallpaper == GlobalWallpaper.none ||
              wallpaper == GlobalWallpaper.custom) {
            expect(asset, isNull);
          } else {
            expect(File(asset!).existsSync(), isTrue, reason: asset);
          }
        }
      }
    }
  });

  test('each built-in wallpaper swaps its own light and dark asset', () {
    for (final wallpaper in [
      GlobalWallpaper.catnap,
      GlobalWallpaper.laketown,
      GlobalWallpaper.sakura,
    ]) {
      final light = wallpaper.assetFor(
        GlobalWallpaperSlot.page,
        Brightness.light,
      );
      final dark = wallpaper.assetFor(
        GlobalWallpaperSlot.page,
        Brightness.dark,
      );
      expect(light, 'assets/wallpapers/${wallpaper.value}_light.webp');
      expect(dark, 'assets/wallpapers/${wallpaper.value}_dark.webp');
      expect(light, isNot(dark));
    }
  });

  test('wallpaper choice is parsed and stays on this device', () {
    final settings = mapUiModelsToAppSettings({'global_wallpaper': 'catnap'});
    expect(settings.globalWallpaper, GlobalWallpaper.catnap);
    expect(
      mapUiModelsToAppSettings({'global_wallpaper': 'laketown'}).globalWallpaper,
      GlobalWallpaper.laketown,
    );
    expect(
      mapUiModelsToAppSettings({'global_wallpaper': 'sakura'}).globalWallpaper,
      GlobalWallpaper.sakura,
    );
    for (final legacy in ['mist', 'apricot']) {
      expect(
        mapUiModelsToAppSettings({'global_wallpaper': legacy}).globalWallpaper,
        GlobalWallpaper.catnap,
      );
    }
    expect(mapUiModelsToAppSettings({}).globalWallpaper, GlobalWallpaper.none);
    expect(localGeneralSettings, contains('global_wallpaper'));

    expect(
      mapUiModelsToAppSettings({}).activeWallpaperStyle,
      const WallpaperStyle(),
    );
    expect(
      localGeneralSettings,
      containsAll([
        'global_wallpaper_customs',
        'global_wallpaper_custom_id',
        'global_wallpaper_styles',
      ]),
    );
  });

  test('several custom wallpapers each keep their own mask and blur', () {
    final settings = mapUiModelsToAppSettings({
      'global_wallpaper': 'custom',
      'global_wallpaper_custom_id': 'b',
      'global_wallpaper_customs': [
        {'id': 'a', 'path': '/tmp/a.png'},
        {'id': 'b', 'path': '/tmp/b.png'},
        {'id': '', 'path': '/tmp/broken.png'},
      ],
      'global_wallpaper_styles': {
        'b': {'mask': 1.5, 'blur': 12},
        'catnap': {'blur': 150},
      },
    });
    expect(settings.globalWallpaperCustoms.map((e) => e.id), ['a', 'b']);
    expect(settings.activeCustomWallpaper?.imagePath, '/tmp/b.png');
    expect(
      settings.activeWallpaperStyle,
      const WallpaperStyle(mask: 1, blur: 12),
    );
    expect(
      settings.wallpaperStyleFor('a', custom: true),
      const WallpaperStyle(mask: kDefaultCustomWallpaperMask),
    );
    expect(
      settings.wallpaperStyleFor('catnap', custom: false),
      const WallpaperStyle(blur: kMaxWallpaperBlur),
    );

    final deleted = mapUiModelsToAppSettings({
      'global_wallpaper': 'custom',
      'global_wallpaper_custom_id': 'gone',
      'global_wallpaper_customs': [
        {'id': 'a', 'path': '/tmp/a.png'},
      ],
    });
    expect(deleted.activeCustomWallpaper, isNull);
  });

  test('the single legacy custom wallpaper becomes a list entry', () {
    final settings = mapUiModelsToAppSettings({
      'global_wallpaper': 'custom',
      'global_wallpaper_custom_image': '/tmp/w.png',
      'global_wallpaper_mask': 0.6,
    });
    expect(settings.globalWallpaperCustoms, [
      const CustomWallpaper(id: 'legacy', imagePath: '/tmp/w.png'),
    ]);
    expect(settings.activeCustomWallpaper?.imagePath, '/tmp/w.png');
    expect(settings.activeWallpaperStyle, const WallpaperStyle(mask: 0.6));
  });

  testWidgets('default page background uses the page wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MoePageScaffold(body: SizedBox())));
    expect(_assetNames(tester), {'assets/wallpapers/catnap_light.webp'});
  });

  testWidgets('pages passing the theme surface still get the wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => MoePageScaffold(
            backgroundColor: context.moeColors.surface,
            body: const SizedBox(),
          ),
        ),
        dark: true,
      ),
    );
    expect(_assetNames(tester), {'assets/wallpapers/catnap_dark.webp'});
  });

  testWidgets('page background widget replaces the global wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MoePageScaffold(
          background: ColoredBox(
            key: Key('role-wallpaper'),
            color: Colors.blue,
          ),
          body: SizedBox(),
        ),
      ),
    );
    expect(find.byKey(const Key('role-wallpaper')), findsOneWidget);
    expect(_assetNames(tester), isEmpty);
  });

  testWidgets('custom page colors keep their own background', (tester) async {
    await tester.pumpWidget(
      _host(
        const MoePageScaffold(backgroundColor: Colors.red, body: SizedBox()),
      ),
    );
    expect(_assetNames(tester), isEmpty);
  });

  testWidgets('no wallpaper keeps the plain color', (tester) async {
    await tester.pumpWidget(
      _host(
        const MoeChatWallpaper(child: SizedBox()),
        wallpaper: GlobalWallpaper.none,
      ),
    );
    expect(_assetNames(tester), isEmpty);
  });

  testWidgets('chat default background uses the chat wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const MoeChatWallpaper(child: SizedBox()), dark: true),
    );
    expect(_assetNames(tester), {'assets/wallpapers/catnap_dark.webp'});
    expect(
      tester.widget<Image>(find.byType(Image)).alignment,
      Alignment.centerLeft,
    );
  });

  testWidgets('the built-in wallpaper follows the theme brightness', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MoePageScaffold(body: SizedBox()),
        wallpaper: GlobalWallpaper.laketown,
      ),
    );
    expect(_assetNames(tester), {'assets/wallpapers/laketown_light.webp'});

    await tester.pumpWidget(
      _host(
        const MoePageScaffold(body: SizedBox()),
        wallpaper: GlobalWallpaper.laketown,
        dark: true,
      ),
    );
    // MaterialApp animates the theme switch, so brightness settles a frame in.
    await tester.pumpAndSettle();
    expect(_assetNames(tester), {'assets/wallpapers/laketown_dark.webp'});
  });

  testWidgets('custom wallpaper covers every page with a readability mask', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MoePageScaffold(body: SizedBox()),
        wallpaper: GlobalWallpaper.custom,
        customImagePath: '/tmp/aicove-custom-wallpaper.png',
      ),
    );
    final image = tester.widget<Image>(find.byType(Image)).image as FileImage;
    expect(image.file.path, '/tmp/aicove-custom-wallpaper.png');
    final scaffoldColor = Theme.of(
      tester.element(find.byType(Scaffold)),
    ).scaffoldBackgroundColor;
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ColoredBox && w.color == scaffoldColor.withValues(alpha: 0.4),
      ),
      findsOneWidget,
    );
  });

  testWidgets('custom wallpaper without an image keeps the plain color', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MoeChatWallpaper(child: SizedBox()),
        wallpaper: GlobalWallpaper.custom,
      ),
    );
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('wallpaper blur applies ImageFiltered Gaussian blur under the mask', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MoeChatWallpaper(child: SizedBox()),
        style: const WallpaperStyle(blur: 15),
      ),
    );
    final filtered = tester.widget<ImageFiltered>(
      find.byKey(const ValueKey('moe_wallpaper_blur')),
    );
    expect(filtered.enabled, isTrue);

    await tester.pumpWidget(_host(const MoeChatWallpaper(child: SizedBox())));
    expect(find.byKey(const ValueKey('moe_wallpaper_blur')), findsNothing);
  });
}
