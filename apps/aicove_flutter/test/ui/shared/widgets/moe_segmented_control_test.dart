import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_segmented_control.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_liquid_glass.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pump(
    WidgetTester tester, {
    String value = 'a',
    bool enabled = true,
    bool glass = false,
  }) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        builder: (context, child) => MoeGlassTheme(
          enabled: glass,
          useLiquidGlass: glass,
          blurSigma: 16,
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: MoeSegmentedControl<String>(
                value: value,
                segments: const [
                  MoeSegment(value: 'a', label: 'A'),
                  MoeSegment(value: 'b', label: 'B'),
                  MoeSegment(value: 'c', label: 'C'),
                ],
                onChanged: enabled ? changes.add : null,
              ),
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('tapping another segment reports its value', (tester) async {
    final changes = await pump(tester);
    await tester.tap(find.text('C'));
    await tester.tap(find.text('A'));
    expect(changes, ['c']);
  });

  testWidgets('dragging across segments selects the one under the pointer',
      (tester) async {
    final changes = await pump(tester);
    await tester.drag(find.text('A'), const Offset(110, 0));
    expect(changes, contains('b'));
  });

  testWidgets('disabled control ignores taps', (tester) async {
    final changes = await pump(tester, enabled: false);
    await tester.tap(find.text('B'));
    expect(changes, isEmpty);
  });

  testWidgets('holding the selected segment lifts it into glass', (tester) async {
    await pump(tester, glass: true);
    expect(find.byType(MoeLiquidGlass), findsNothing);
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MoeLiquidGlass), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(MoeLiquidGlass), findsNothing);
  });

  testWidgets('a lifted thumb lands on the segment under the finger',
      (tester) async {
    final changes = await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, ['b']);
  });

  testWidgets('solid material keeps the accent pill and never lifts',
      (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MoeLiquidGlass), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    await gesture.up();
  });

  testWidgets('tapping another segment slides without lifting', (tester) async {
    await pump(tester, glass: true);
    await tester.tap(find.text('B'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(MoeLiquidGlass), findsNothing);
  });
}
