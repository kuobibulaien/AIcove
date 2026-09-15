import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';

void main() {
  for (final width in [320.0, 390.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('inline input uses remaining width: $width / $scale', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const Scaffold(
                body: MoeSettingsGroup(
                  children: [
                    MoeSettingsRow(
                      label: '基础 URL',
                      expandTrailing: true,
                      trailingType: MoeSettingsRowTrailing.custom,
                      trailing: TextField(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final label = tester.getRect(find.text('基础 URL'));
        final input = tester.getRect(find.byType(TextField));
        expect(input.left - label.right, closeTo(12, 0.1));
        expect(input.right, closeTo(width - 12, 1));
        expect(input.width, greaterThan(0));
        if (width >= 390 && scale == 1) {
          expect(input.width, greaterThan(220));
        }
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byType(TextField),
          'https://example.com/v1',
        );
        expect(find.text('https://example.com/v1'), findsOneWidget);
      });
    }
  }
}
