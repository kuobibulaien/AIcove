import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/moe_frosted_material.dart';
import 'package:aicove_flutter/src/ui/theme/moe_glass_theme.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  test('dark containers sit one step lighter than the page background', () {
    final colors = MoeColors.dark();
    expect(
      colors.componentBackground.computeLuminance(),
      greaterThan(colors.surface.computeLuminance()),
    );
    expect(colors.panel, colors.componentBackground);
    expect(moeTalkColorSchemeDark.surface, colors.surface);
    expect(moeTalkColorSchemeDark.surfaceContainer, colors.componentBackground);
  });

  test('solid containers match the frosted tint over the dark page', () {
    final colors = MoeColors.dark();
    for (final setting in [3.2, 16.0, 32.0]) {
      final frosted = Color.alphaBlend(
        MoeFrostedMaterial.surfaceTint(
          Brightness.dark,
          fill: setting / kMaxGlassBlurSigma,
        ),
        colors.surface,
      );
      expect(
        frosted.toARGB32(),
        colors.componentBackground.toARGB32(),
        reason: 'setting=$setting',
      );
    }
  });

  for (final dark in [false, true]) {
    testWidgets('solid floating surface paints the container color $dark', (
      tester,
    ) async {
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            extensions: [colors],
          ),
          home: const MoeGlassTheme(
            enabled: false,
            blurSigma: 16,
            child: Center(
              child: MoeFloatingSurface(child: SizedBox(width: 80, height: 40)),
            ),
          ),
        ),
      );
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(MoeFloatingSurface),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, colors.componentBackground);
    });
  }
}
