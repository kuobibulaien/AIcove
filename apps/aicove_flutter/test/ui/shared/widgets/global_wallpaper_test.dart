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
  GlobalWallpaper wallpaper = GlobalWallpaper.mist,
  bool dark = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      extensions: [dark ? MoeColors.dark() : MoeColors.light()],
    ),
    home: MoeWallpaperTheme(wallpaper: wallpaper, child: child),
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
          if (wallpaper == GlobalWallpaper.none) {
            expect(asset, isNull);
          } else {
            expect(File(asset!).existsSync(), isTrue, reason: asset);
          }
        }
      }
    }
  });

  test('wallpaper choice is parsed and stays on this device', () {
    final settings = mapUiModelsToAppSettings({'global_wallpaper': 'apricot'});
    expect(settings.globalWallpaper, GlobalWallpaper.apricot);
    expect(
      mapUiModelsToAppSettings({}).globalWallpaper,
      GlobalWallpaper.none,
    );
    expect(localGeneralSettings, contains('global_wallpaper'));
  });

  testWidgets('default page background uses the page wallpaper', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const MoePageScaffold(body: SizedBox())));
    expect(_assetNames(tester), {'assets/wallpapers/mist_3_light.webp'});
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
    expect(_assetNames(tester), {'assets/wallpapers/mist_3_dark.webp'});
  });

  testWidgets('custom page colors keep their own background', (tester) async {
    await tester.pumpWidget(
      _host(const MoePageScaffold(backgroundColor: Colors.red, body: SizedBox())),
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
      _host(
        const MoeChatWallpaper(child: SizedBox()),
        wallpaper: GlobalWallpaper.apricot,
      ),
    );
    expect(_assetNames(tester), {'assets/wallpapers/apricot_2_light.webp'});
  });
}
