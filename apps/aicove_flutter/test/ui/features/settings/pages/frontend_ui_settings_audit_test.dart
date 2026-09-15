import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/ui_settings_page.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('UI settings default content size=$size scale=$scale',
          (tester) async {
        final originalErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          debugPrint(details.toString());
          originalErrorHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalErrorHandler);
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(ProviderScope(
            child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: const UiSettingsPage(),
        )));
        final container = ProviderScope.containerOf(
            tester.element(find.byType(UiSettingsPage)));
        // 设置存储链含全局串行写队列，部分环节只随真实事件循环推进；
        // 先让真实队列跑一小段把挂起的写链冲掉，再在假时钟里读状态。
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await container.read(appSettingsProvider.future);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scroll = find.byType(Scrollable).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(scroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
