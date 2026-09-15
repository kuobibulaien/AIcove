import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    for (final mode in MoeSurfaceMaterial.values) {
      testWidgets(
        'text tint preserves fixed frosted recipe for $mode dark=$dark',
        (tester) async {
          MoeLiquidGlassService.setMockState(available: true);
          addTearDown(
            () => MoeLiquidGlassService.setMockState(available: false),
          );
          final colors = dark ? MoeColors.dark() : MoeColors.light();
          for (final sigma in [0.0, 16.0, 32.0]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  extensions: [colors],
                ),
                home: MoeGlassTheme(
                  enabled: mode != MoeSurfaceMaterial.solid,
                  useLiquidGlass: mode == MoeSurfaceMaterial.liquid,
                  blurSigma: sigma,
                  child: const Column(
                    children: [
                      MoeFloatingSurface(child: Text('Floating')),
                      MoeFloatingSurface(
                        baseline: MoeMaterialBaseline.background,
                        child: Text('Background'),
                      ),
                      MoeFloatingSurface(
                        baseline: MoeMaterialBaseline.text,
                        child: Text('Text surface'),
                      ),
                    ],
                  ),
                ),
              ),
            );
            await tester.pump();
            final tints = tester
                .widgetList<Ink>(find.byType(Ink))
                .where(
                  (ink) =>
                      (ink.decoration as BoxDecoration?)?.color !=
                      Colors.transparent,
                )
                .toList();
            if (mode == MoeSurfaceMaterial.frosted) {
              expect(
                tints,
                isEmpty,
                reason: 'Cupertino supplies the complete tint',
              );
            } else {
              expect(tints, hasLength(1));
              expect(
                (tints.single.decoration as BoxDecoration).color,
                colors.surface.withValues(alpha: 0.06),
              );
            }
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
}
