import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/custom_skin_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('主题色：默认／晴空／自定义三格，与壁纸格同宽；自定义可分别选浅色深色', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: UiSettingsPage())),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UiSettingsPage)),
    );
    await tester.runAsync(() => container.read(appSettingsProvider.future));
    await tester.pumpAndSettle();
    AppSettings settings() => container.read(appSettingsProvider).requireValue;

    expect(find.text('主题色'), findsOneWidget);
    expect(find.text('界面皮肤'), findsNothing);
    expect(find.text('Momotalk'), findsNothing);
    expect(find.text('暖笺'), findsNothing);
    expect(find.text('自定义皮肤'), findsNothing);

    Finder skin(InterfaceSkin s) =>
        find.byKey(ValueKey('interface-skin-${s.value}'));
    expect(InterfaceSkin.values, hasLength(3));
    final wallpaperWidth = tester
        .getSize(find.byKey(const ValueKey('global-wallpaper-none')))
        .width;
    for (final s in InterfaceSkin.values) {
      expect(tester.getSize(skin(s)).width, closeTo(wallpaperWidth, 0.5));
    }

    await tester.tap(skin(InterfaceSkin.custom));
    await tester.pumpAndSettle();
    expect(settings().interfaceSkin, InterfaceSkin.custom);
    expect(find.byType(CustomSkinPage), findsOneWidget);
    expect(find.text('浅色模式'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('浅色聊天背景'), findsNothing);
    expect(find.text('聊天背景色'), findsNothing);

    // 每种模式的预设和取色器排在同一行。
    for (final mode in ['custom-accent-light', 'custom-accent-dark']) {
      final circles = find.descendant(
        of: find.byKey(ValueKey(mode)),
        matching: find.byType(GestureDetector),
      );
      expect(circles, findsNWidgets(8));
      final tops = {
        for (final e in circles.evaluate())
          tester.getTopLeft(find.byWidget(e.widget)).dy,
      };
      expect(tops, hasLength(1));
    }
  });
}
