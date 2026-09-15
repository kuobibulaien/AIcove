import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  group('MoeColors glass tokens', () {
    test('light and dark themes populate glass tokens', () {
      final light = MoeColors.light();
      final dark = MoeColors.dark();

      expect(light.glassSurface.a, lessThanOrEqualTo(0.36));
      expect(dark.glassSurface.a, lessThanOrEqualTo(0.30));
      expect(
        dark.glassSurface.r,
        dark.glassSurface.b,
        reason: 'Dark glass must not dye wallpaper blue',
      );
      expect(
        MoeColors.light(globalBgColor: Colors.pink).glassSurface,
        light.glassSurface,
        reason: 'Wallpaper color is not a material tint',
      );

      expect(light.glassBorder, isNotNull);
      expect(dark.glassBorder, isNotNull);
      expect(light.glassShadow, isNotNull);
      expect(dark.glassShadow, isNotNull);
    });

    test('copyWith preserves and overrides glass tokens', () {
      final base = MoeColors.light();
      const customGlass = Color(0xAA112233);
      final copied = base.copyWith(glassSurface: customGlass);

      expect(copied.glassSurface, customGlass);
      expect(copied.glassBorder, base.glassBorder);
      expect(copied.glassShadow, base.glassShadow);
    });

    test('lerp correctly blends glass tokens', () {
      final a = MoeColors.light().copyWith(
        glassSurface: const Color(0x00000000),
      );
      final b = MoeColors.light().copyWith(
        glassSurface: const Color(0xFFFFFFFF),
      );

      final mid = a.lerp(b, 0.5);
      expect(
        mid.glassSurface.toARGB32(),
        Color.lerp(a.glassSurface, b.glassSurface, 0.5)!.toARGB32(),
      );
    });
  });

  group('MoeFloatingSurface with MoeGlassTheme', () {
    Widget buildSubject({
      bool? glassThemeEnabled,
      double? glassThemeSigma,
      bool? surfaceBlurEnabled,
      double? surfaceBlurSigma,
      bool highContrast = false,
    }) {
      Widget tree = MoeFloatingSurface(
        blurEnabled: surfaceBlurEnabled,
        blurSigma: surfaceBlurSigma,
        child: const Text('Floating Content'),
      );

      if (glassThemeEnabled != null || glassThemeSigma != null) {
        tree = MoeGlassTheme(
          useLiquidGlass: true,
          enabled: glassThemeEnabled ?? true,
          blurSigma: glassThemeSigma ?? kDefaultGlassBlurSigma,
          child: tree,
        );
      }

      return MaterialApp(
        theme: ThemeData(extensions: [MoeColors.light()]),
        home: MediaQuery(
          data: MediaQueryData(highContrast: highContrast),
          child: Scaffold(body: tree),
        ),
      );
    }

    testWidgets(
      'enabled glass theme renders BackdropFilter with glass surface color',
      (tester) async {
        await tester.pumpWidget(
          buildSubject(glassThemeEnabled: true, glassThemeSigma: 16.0),
        );

        final backdropFilterFinder = find.byType(BackdropFilter);
        expect(backdropFilterFinder, findsOneWidget);

        final filterWidget = tester.widget<BackdropFilter>(
          backdropFilterFinder,
        );
        expect(filterWidget.filter, isNotNull);

        final materialFinder = find.descendant(
          of: find.byType(MoeFloatingSurface),
          matching: find.byType(Material),
        );
        expect(materialFinder, findsOneWidget);
        final material = tester.widget<Material>(materialFinder);
        final colors = MoeColors.light();
        expect(material.color!.a, closeTo(0.18, 0.0001));
        expect(material.color!.withValues(alpha: 1), colors.surface);
      },
    );

    testWidgets(
      'disabled glass theme skips BackdropFilter and uses fallback surface color',
      (tester) async {
        await tester.pumpWidget(buildSubject(glassThemeEnabled: false));

        expect(find.byType(BackdropFilter), findsNothing);

        final materialFinder = find.descendant(
          of: find.byType(MoeFloatingSurface),
          matching: find.byType(Material),
        );
        final material = tester.widget<Material>(materialFinder);
        final colors = MoeColors.light();
        expect(material.color, colors.surface);
      },
    );

    testWidgets('floating zero strength removes tint and blur', (tester) async {
      await tester.pumpWidget(
        buildSubject(glassThemeEnabled: true, glassThemeSigma: 0.0),
      );

      expect(find.byType(BackdropFilter), findsNothing);

      final materialFinder = find.descendant(
        of: find.byType(MoeFloatingSurface),
        matching: find.byType(Material),
      );
      final material = tester.widget<Material>(materialFinder);
      expect(material.color!.a, 0);
    });

    testWidgets(
      'high-contrast mode forces fallback surface and skips BackdropFilter',
      (tester) async {
        await tester.pumpWidget(
          buildSubject(
            glassThemeEnabled: true,
            glassThemeSigma: 16.0,
            highContrast: true,
          ),
        );

        expect(find.byType(BackdropFilter), findsNothing);

        final materialFinder = find.descendant(
          of: find.byType(MoeFloatingSurface),
          matching: find.byType(Material),
        );
        final material = tester.widget<Material>(materialFinder);
        final colors = MoeColors.light();
        expect(material.color, colors.surface);
      },
    );

    testWidgets('component-level blurEnabled and blurSigma override theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildSubject(
          glassThemeEnabled: true,
          glassThemeSigma: 16.0,
          surfaceBlurEnabled: false,
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);
      final materialFinder = find.descendant(
        of: find.byType(MoeFloatingSurface),
        matching: find.byType(Material),
      );
      final material = tester.widget<Material>(materialFinder);
      expect(material.color, MoeColors.light().surface);
    });
  });
}
