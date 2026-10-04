import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

Widget _panel({
  required double width,
  required double height,
  bool liquid = false,
  bool dark = false,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    extensions: [dark ? MoeColors.dark() : MoeColors.light()],
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: MoeGlassTheme(
      enabled: true,
      useLiquidGlass: liquid,
      blurSigma: 16,
      child: child!,
    ),
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: MoeFloatingSurface(child: ComposerMorePanel(onAction: (_) {})),
      ),
    ),
  ),
);

Rect _tile(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(MoreActionTile)),
);

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: true));
  tearDown(() => MoeLiquidGlassService.setMockState());

  for (final dark in [false, true]) {
    for (final liquid in [false, true]) {
      testWidgets('more panel buttons keep global material $dark $liquid', (
        tester,
      ) async {
        await tester.pumpWidget(
          _panel(width: 388, height: 286, dark: dark, liquid: liquid),
        );
        final tiles = find.byType(MoreActionTile);
        expect(tiles, findsNWidgets(5));
        for (final tile in tiles.evaluate()) {
          final material = find.descendant(
            of: find.byWidget(tile.widget),
            matching: liquid
                ? find.byType(AdaptiveGlass)
                : find.byType(BackdropFilter),
          );
          expect(material, findsWidgets, reason: '几乎不滚的面板不应退回纯色');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final size in [
    const Size(296, 286), // narrow desktop window, default panel height
    const Size(388, 286), // common phone keyboard height
    const Size(388, 340), // taller phone keyboard
    const Size(976, 286), // wide desktop detail pane
  ]) {
    testWidgets('more panel is a full-width folder grid $size', (tester) async {
      await tester.pumpWidget(_panel(width: size.width, height: size.height));
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, 0, reason: '常规高度不滚动');

      final panel = tester.getRect(find.byType(ComposerMorePanel));
      final model = _tile(tester, '模型');
      final thinking = _tile(tester, '思考');
      final gallery = _tile(tester, '相册');
      final attachment = _tile(tester, '附件');
      final call = _tile(tester, '通话');
      expect(find.text('拍照'), findsNothing);
      expect(model.width, moreOrLessEquals(model.height));

      // One gap everywhere: left/right/top margins, row gap and column gap.
      final gap = thinking.left - model.right;
      expect(gap, greaterThanOrEqualTo(16));
      expect(model.width, lessThanOrEqualTo(90.001), reason: '按钮边长不超过 90');
      if (size.width >= 360) {
        expect(model.width, greaterThanOrEqualTo(79.999), reason: '常规宽度按钮不小于 80');
      }
      expect(gallery.left - thinking.right, moreOrLessEquals(gap));
      expect(model.left - panel.left, moreOrLessEquals(gap));
      expect(model.top - panel.top, moreOrLessEquals(gap));

      final columns = ((panel.width - gap) / (model.width + gap)).round();
      expect(columns, greaterThanOrEqualTo(3));
      final rightMargin =
          panel.right -
          (model.left + columns * model.width + (columns - 1) * gap);
      expect(rightMargin, moreOrLessEquals(gap), reason: '宫格铺满宽度，左右边距一致');

      if (columns == 3) {
        // Six-grid: attachment and call start the second row.
        expect(attachment.left, moreOrLessEquals(model.left));
        expect(call.left, moreOrLessEquals(thinking.left));
        expect(attachment.top - model.bottom, moreOrLessEquals(gap));
      } else {
        expect(call.top, moreOrLessEquals(model.top));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text falls back to scrolling without losing material', (
    tester,
  ) async {
    await tester.pumpWidget(_panel(width: 296, height: 160, textScale: 1.8));
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
