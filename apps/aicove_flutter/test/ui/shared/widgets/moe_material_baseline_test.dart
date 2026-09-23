import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  test('glass blur stays see-through through the lower half', () {
    const none = MoeMaterialBaseline.none;
    expect(none.blurSigma(8), closeTo(0.75, 0.0001));
    expect(none.blurSigma(kDefaultGlassBlurSigma), closeTo(3, 0.0001));
    expect(none.blurSigma(kMaxGlassBlurSigma), kMaxLiquidGlassBlurSigma);
    expect(MoeMaterialBaseline.text.blurSigma(16), lessThan(5));
  });
  for (final baseline in [
    MoeMaterialBaseline.none,
    MoeMaterialBaseline.background,
    MoeMaterialBaseline.text,
    const MoeMaterialBaseline(blurFactor: 0.2, tintOpacity: 0.05),
  ]) {
    for (final dark in [false, true]) {
      test(
        'independent minimums dark=$dark blur=${baseline.blurFactor} tint=${baseline.tintOpacity}',
        () {
          final colors = dark ? MoeColors.dark() : MoeColors.light();
          expect(
            baseline.blurSigma(0),
            closeTo(
              kMaxLiquidGlassBlurSigma *
                  baseline.blurFactor *
                  baseline.blurFactor,
              0.0001,
            ),
          );
          expect(
            colors.glassTintForSigma(0, baseline: baseline).a,
            closeTo(baseline.tintOpacity, 0.0001),
          );
          expect(baseline.blurSigma(32), kMaxLiquidGlassBlurSigma);
          expect(
            colors.glassTintForSigma(32, baseline: baseline).a,
            closeTo(
              baseline.tintOpacity +
                  (1 - baseline.tintOpacity) * colors.glassSurface.a,
              0.0001,
            ),
          );
          expect(baseline.blurSigma(16), greaterThan(baseline.blurSigma(0)));
          expect(
            colors.glassTintForSigma(16, baseline: baseline).a,
            greaterThan(colors.glassTintForSigma(0, baseline: baseline).a),
          );
        },
      );
    }
  }
  for (final liquid in [false, true]) {
    testWidgets(
      'text opt-in and floating zero remain separate liquid=$liquid',
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
          expect(surfaces[1].settings.glassColor.a, closeTo(0.1, 0.0001));
          expect(surfaces[1].settings.blur, closeTo(0.12, 0.0001));
        } else {
          expect(find.byType(BackdropFilter), findsOneWidget);
          final surfaces = tester
              .widgetList<Material>(find.byType(Material))
              .where((m) => m.color != null)
              .toList();
          expect(surfaces.any((m) => m.color!.a == 0), isTrue);
          expect(
            surfaces.any((m) => (m.color!.a - 0.1).abs() < 0.0001),
            isTrue,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
