import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/global_wallpaper_edit_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

void main() {
  testWidgets('custom wallpapers: add tile, select, edit, delete', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Directory root;
    late File first;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('global_wallpaper_picker');
      first = File('${root.path}/wallpapers/a.png');
      await first.create(recursive: true);
    });
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(root.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
    SharedPreferences.setMockInitialValues({
      'aicove.ui_models.v1': jsonEncode({
        'global_wallpaper': 'catnap',
        'global_wallpaper_customs': [
          {'id': 'a', 'path': first.path},
          {'id': 'b', 'path': '${root.path}/wallpapers/b.png'},
        ],
      }),
    });

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: UiSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    await tester.pumpAndSettle();
    AppSettings settings() => container.read(appSettingsProvider).requireValue;

    expect(find.text('自定义 1'), findsOneWidget);
    expect(find.text('自定义 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('global-wallpaper-add')), findsOneWidget);
    expect(find.text('更换图片'), findsNothing);
    expect(find.text('壁纸遮罩'), findsNothing);

    // 第一次点切换，第二次点进入编辑页。
    final tile = find.byKey(const ValueKey('global-wallpaper-custom-a'));
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(settings().activeCustomWallpaper?.id, 'a');
    expect(find.byType(GlobalWallpaperEditPage), findsNothing);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalWallpaperEditPage), findsOneWidget);

    final mask = find.byKey(const ValueKey('wallpaper_mask_slider'));
    final blur = find.byKey(const ValueKey('wallpaper_blur_slider'));
    tester
        .widget<MoeSlider>(
          find.descendant(of: mask, matching: find.byType(MoeSlider)),
        )
        .onChanged!(0.7);
    tester
        .widget<MoeSlider>(
          find.descendant(of: blur, matching: find.byType(MoeSlider)),
        )
        .onChanged!(10);
    await tester.pump();
    expect(find.text('70%'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      settings().activeWallpaperStyle,
      const WallpaperStyle(mask: 0.7, blur: 10),
    );
    expect(
      settings().wallpaperStyleFor('b', custom: true),
      const WallpaperStyle(mask: kDefaultCustomWallpaperMask),
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wallpaper_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    // 删除图片走真实文件 IO，等它做完再看页面。
    final editPage = find.byType(GlobalWallpaperEditPage);
    for (var i = 0; i < 20 && editPage.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(editPage, findsNothing);
    expect(settings().globalWallpaperCustoms.map((e) => e.id), ['b']);
    expect(settings().globalWallpaper, GlobalWallpaper.none);
    expect(settings().globalWallpaperStyles.containsKey('a'), isFalse);
    expect(first.existsSync(), isFalse);
    expect(find.text('自定义'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
