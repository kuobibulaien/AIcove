import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {bool dark = false}) => MaterialApp(
  theme: ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    extensions: [dark ? MoeColors.dark() : MoeColors.light()],
  ),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  for (final dark in [false, true]) {
    testWidgets('choice chip keeps text readable and tints selection '
        'dark=$dark', (tester) async {
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        _wrap(
          dark: dark,
          const Wrap(
            children: [
              MoeChoiceChip(label: '选中', selected: true, onTap: _noop),
              MoeChoiceChip(label: '未选', selected: false, onTap: _noop),
            ],
          ),
        ),
      );
      for (final label in ['选中', '未选']) {
        expect(tester.widget<Text>(find.text(label)).style!.color, colors.text);
      }
      final surfaces = tester
          .widgetList<MoeButtonSurface>(find.byType(MoeButtonSurface))
          .toList();
      expect(surfaces[0].tintColor, colors.primary);
      expect(
        (surfaces[0].border! as Border).top.color,
        colors.primary,
      );
      expect(surfaces[1].tintColor, isNull);
      // Chips in a Wrap size to their label instead of filling the row.
      expect(
        tester.getSize(find.byType(MoeChoiceChip).first).width,
        lessThan(200),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disabled choice chip ignores taps and reports state', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            const MoeChoiceChip(label: '禁用', selected: false, onTap: null),
            MoeChoiceChip(
              label: '可用',
              selected: false,
              indicator: MoeChoiceIndicator.check,
              onTap: () => taps++,
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('禁用'));
    await tester.tap(find.text('可用'));
    expect(taps, 1);
    final semantics = tester.getSemantics(find.text('可用'));
    expect(semantics.flagsCollection.isButton, isTrue);
  });

  testWidgets('slidable actions use material tint, not a solid fill', (
    tester,
  ) async {
    final colors = MoeColors.light();
    String? pressed;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 360,
          height: 72,
          child: Slidable(
            endActionPane: ActionPane(
              motion: const ScrollMotion(),
              extentRatio: 0.5,
              children: [
                MoeSlidableAction(
                  icon: Icons.push_pin_outlined,
                  label: '置顶',
                  onPressed: (_) => pressed = 'pin',
                ),
                MoeSlidableAction(
                  icon: Icons.delete_outline,
                  label: '删除',
                  destructive: true,
                  onPressed: (_) => pressed = 'delete',
                ),
              ],
            ),
            child: const SizedBox.expand(child: Text('行')),
          ),
        ),
      ),
    );
    await tester.drag(find.text('行'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    final surfaces = tester
        .widgetList<MoeButtonSurface>(find.byType(MoeButtonSurface))
        .toList();
    expect(surfaces, hasLength(2));
    expect(surfaces[0].tintColor!.a, lessThan(1));
    expect(surfaces[1].tintColor!.toARGB32() & 0xFFFFFF,
        colors.toastError.toARGB32() & 0xFFFFFF);
    expect(tester.widget<Text>(find.text('删除')).style!.color, colors.text);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(pressed, 'delete');
    expect(tester.takeException(), isNull);
  });
}

void _noop() {}
