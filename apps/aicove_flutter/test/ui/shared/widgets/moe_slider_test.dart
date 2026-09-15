import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 300, child: child)),
        ),
      );

  testWidgets('MoeSlider 无极调节输出连续值', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      wrap(MoeSlider(value: 0, min: 0, max: 32, onChanged: values.add)),
    );
    final rect = tester.getRect(find.byType(MoeSlider));
    await tester.dragFrom(
      rect.centerLeft,
      Offset(rect.width * 0.613, 0),
    );
    await tester.pump();
    expect(values, isNotEmpty);
    expect(values.last, greaterThan(0));
    expect(values.last, lessThan(32));
    expect(
      values.last,
      isNot(equals(values.last.roundToDouble())),
      reason: '未设置 divisions 时不得吸附到整数',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('MoeSlider divisions 只保留吸附语义', (tester) async {
    final values = <double>[];
    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 0,
          min: 0,
          max: 32,
          divisions: 2,
          onChanged: values.add,
        ),
      ),
    );
    final rect = tester.getRect(find.byType(MoeSlider));
    await tester.dragFrom(
      rect.centerLeft,
      Offset(rect.width * 0.4, 0),
    );
    await tester.pump();
    expect(values.last, 16);
  });

  testWidgets('MoeSlider 轨道不渲染刻度点', (tester) async {
    await tester.pumpWidget(
      wrap(
        MoeSlider(
          value: 8,
          min: 0,
          max: 32,
          divisions: 4,
          onChanged: (_) {},
        ),
      ),
    );
    final theme = tester.widget<SliderTheme>(
      find.descendant(
        of: find.byType(MoeSlider),
        matching: find.byType(SliderTheme),
      ),
    );
    expect(theme.data.tickMarkShape, SliderTickMarkShape.noTickMark);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MoeSlider 禁用态可渲染', (tester) async {
    await tester.pumpWidget(
      wrap(const MoeSlider(value: 8, min: 0, max: 32)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
