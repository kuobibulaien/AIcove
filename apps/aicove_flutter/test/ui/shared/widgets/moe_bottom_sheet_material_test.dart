import 'package:aicove_flutter/src/ui/shared/widgets/sheets/moe_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final width in [420.0, 1000.0]) {
      testWidgets(
        'sheet ListTile ink remains above decoration $brightness $width',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 720));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                body: MoeBottomSheet(
                  title: '选择预设',
                  child: ListTile(
                    title: const Text('测试预设'),
                    onTap: () => taps++,
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('测试预设'));
          await tester.pumpAndSettle();
          expect(taps, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
