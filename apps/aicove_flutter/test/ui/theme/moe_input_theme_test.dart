import 'package:aicove_flutter/src/ui/theme/moe_input_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('floating label stays inside the filled input box',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        inputDecorationTheme: buildMoeInputDecorationTheme(
          isDark: false,
          accent: Colors.pink,
        ),
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: TextFormField(
            initialValue: '纳西妲',
            decoration: const InputDecoration(labelText: '预设名称'),
          ),
        ),
      ),
    ));

    final box = tester.getRect(find.byType(InputDecorator));
    final label = tester.getRect(find.text('预设名称'));
    final value = tester.getRect(find.text('纳西妲'));
    expect(label.top, greaterThanOrEqualTo(box.top));
    expect(label.bottom, lessThanOrEqualTo(value.top));
    expect(value.bottom, lessThanOrEqualTo(box.bottom));
  });

  test('borderless fields stay borderless in every state', () {
    final theme =
        buildMoeInputDecorationTheme(isDark: false, accent: Colors.pink);
    final collapsed =
        const InputDecoration.collapsed(hintText: '消息').applyDefaults(theme);
    expect(collapsed.border, InputBorder.none);
    expect(collapsed.focusedBorder, isNull);
    expect(collapsed.enabledBorder, isNull);
    expect(collapsed.errorBorder, isNull);
  });

  test('default fields get an accent border only when focused', () {
    final border = buildMoeInputDecorationTheme(
      isDark: false,
      accent: Colors.pink,
    ).border! as WidgetStateProperty<InputBorder>;
    expect(border.resolve({WidgetState.focused}).borderSide.color,
        Colors.pink);
    expect(border.resolve({}).borderSide.color, isNot(Colors.pink));
    expect(border.resolve({}).isOutline, isFalse);
  });

  testWidgets('focused labelled field draws a closed border without a gap',
      (tester) async {
    const accent = Color(0xFFE91E63);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        inputDecorationTheme:
            buildMoeInputDecorationTheme(isDark: false, accent: accent),
      ),
      home: Scaffold(
        body: TextFormField(
          focusNode: focus,
          initialValue: '纳西妲',
          decoration: const InputDecoration(labelText: '预设名称'),
        ),
      ),
    ));
    focus.requestFocus();
    await tester.pumpAndSettle();

    expect(
      tester.renderObject(find.byType(InputDecorator)),
      paints
        ..rrect()
        ..rrect(color: accent),
    );
  });
}
