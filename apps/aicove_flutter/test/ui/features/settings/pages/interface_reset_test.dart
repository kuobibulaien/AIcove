import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/widgets/settings_load_failed_view.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Widget app(bool dark, Widget home) => ProviderScope(
        child: MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            extensions: [dark ? MoeColors.dark() : MoeColors.light()],
          ),
          home: home,
        ),
      );

  for (final dark in [false, true]) {
    testWidgets('interface settings reset row asks to confirm dark=$dark',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1600);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(dark, const UiSettingsPage()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('恢复默认界面设置'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('恢复默认界面设置'));
      await tester.pumpAndSettle();
      expect(find.text('恢复'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('settings load failed view offers the reset dark=$dark',
        (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(dark, const SettingsLoadFailedView()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('加载设置失败'), findsOneWidget);
      expect(find.text('恢复默认界面设置'), findsOneWidget);
    });
  }
}
