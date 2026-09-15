import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/settings_drawer_wrapper.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets(
      'settings drawer can reopen while closing without a dropped tap $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = GlobalKey<SettingsDrawerWrapperState>();
        const panel = ValueKey('panel');
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsDrawerWrapper(
              key: key,
              settingsBuilder: (_) => const SizedBox.expand(key: panel),
              child: const SizedBox.expand(),
            ),
          ),
        );
        key.currentState!.open();
        await tester.pumpAndSettle();
        key.currentState!.close();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        key.currentState!.open();
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byKey(panel), findsOneWidget);
        for (var i = 0; i < 4; i++) {
          key.currentState!.close();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 32));
          key.currentState!.open();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
        }
        await tester.pumpAndSettle();
        expect(find.byKey(panel), findsOneWidget);
        key.currentState!.close();
        await tester.pumpAndSettle();
        expect(find.byKey(panel), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
