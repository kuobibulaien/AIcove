import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  test('glass blur stays see-through through the lower half', () {
    const component = MoeMaterialBaseline.component;
    expect(component.blurSigma(8), closeTo(1.25, 0.0001));
    // The recommended midpoint is liquid_glass_widgets' iOS 26 default.
    expect(component.blurSigma(kDefaultGlassBlurSigma), closeTo(5, 0.0001));
    expect(component.blurSigma(kMaxGlassBlurSigma), kMaxLiquidGlassBlurSigma);
    expect(MoeMaterialBaseline.background.blurSigma(16), lessThan(8));
  });
  for (final baseline in [
    MoeMaterialBaseline.component,
    MoeMaterialBaseline.background,
  ]) {
    test('blur minimum only blur=${baseline.blurFactor}', () {
      expect(
        baseline.blurSigma(0),
        closeTo(
          kMaxLiquidGlassBlurSigma * baseline.blurFactor * baseline.blurFactor,
          0.0001,
        ),
      );
      expect(baseline.blurSigma(32), kMaxLiquidGlassBlurSigma);
      expect(baseline.blurSigma(16), greaterThan(baseline.blurSigma(0)));
    });
  }
  for (final dark in [false, true]) {
    test('tint follows the fill alone dark=$dark', () {
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      expect(colors.glassTintForFill(0).a, 0);
      expect(
        colors.glassTintForFill(1).a,
        closeTo(colors.glassSurface.a, 0.0001),
      );
      expect(
        colors.glassTintForFill(0.5).a,
        closeTo(colors.glassSurface.a / 2, 0.0001),
      );
    });
  }
  for (final liquid in [false, true]) {
    testWidgets(
      'background keeps a blur minimum but no tint minimum liquid=$liquid',
      (tester) async {
        MoeLiquidGlassService.setMockState(
          initialized: true,
          available: liquid,
        );
        addTearDown(
          () => MoeLiquidGlassService.setMockState(
            initialized: false,
            available: false,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MoeGlassTheme(
              enabled: true,
              blurSigma: 0,
              tintFill: 0,
              useLiquidGlass: true,
              child: const Column(
                children: [
                  MoeFloatingSurface(child: Text('悬浮')),
                  MoeBottomSheet(title: '文字面板', child: Text('内容')),
                ],
              ),
            ),
          ),
        );
        if (liquid) {
          final surfaces = tester
              .widgetList<AdaptiveGlass>(find.byType(AdaptiveGlass))
              .toList();
          expect(surfaces[0].settings.glassColor.a, 0);
          expect(surfaces[0].settings.blur, 0);
          expect(surfaces[1].settings.glassColor.a, 0);
          expect(surfaces[1].settings.blur, closeTo(1.25, 0.0001));
        } else {
          expect(find.byType(BackdropFilter), findsOneWidget);
          final surfaces = tester
              .widgetList<Material>(find.byType(Material))
              .where((m) => m.color != null)
              .toList();
          expect(surfaces.every((m) => m.color!.a == 0), isTrue);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
