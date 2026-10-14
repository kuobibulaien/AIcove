import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/moe_frosted_material.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

Widget _wrap({
  required Widget child,
  bool dark = false,
  bool glassEnabled = false,
  bool liquid = false,
  double blurSigma = 16,
  double tintFill = kDefaultGlassTintFill,
  bool highContrast = false,
  bool reduceTransparency = false,
}) {
  final colors = dark ? MoeColors.dark() : MoeColors.light();
  return MaterialApp(
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      extensions: [colors],
    ),
    builder: (context, child) => MoeGlassTheme(
      enabled: glassEnabled,
      blurSigma: blurSigma,
      tintFill: tintFill,
      useLiquidGlass: liquid,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(highContrast: highContrast),
        child: GlassAccessibilityScope(
          reduceTransparency: reduceTransparency,
          child: child!,
        ),
      ),
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

Material _surfaceMaterial(WidgetTester tester) {
  return tester.widget<Material>(
    find
        .descendant(
          of: find.byType(MoeContentSurface),
          matching: find.byType(Material),
        )
        .first,
  );
}

void main() {
  tearDown(() => MoeLiquidGlassService.setMockState());

  testWidgets('solid mode stays opaque componentBackground', (tester) async {
    await tester.pumpWidget(
      _wrap(child: const MoeContentSurface(child: Text('内容'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      _surfaceMaterial(tester).color,
      MoeColors.light().componentBackground,
    );
  });

  for (final dark in [false, true]) {
    for (final liquid in [false, true]) {
      testWidgets('global material dark=$dark liquid=$liquid', (tester) async {
        MoeLiquidGlassService.setMockState(available: true);
        final brightness = dark ? Brightness.dark : Brightness.light;
        await tester.pumpWidget(
          _wrap(
            dark: dark,
            glassEnabled: true,
            liquid: liquid,
            blurSigma: 32,
            tintFill: 0.8,
            child: const MoeContentSurface(child: Text('内容')),
          ),
        );
        await tester.pumpAndSettle();
        if (liquid) {
          // Glass matches the floating bars: component blur and glass rim.
          final glass = tester.widget<MoeLiquidGlass>(
            find.byType(MoeLiquidGlass),
          );
          expect(glass.baseline, MoeMaterialBaseline.component);
          expect(glass.border, isNull);
          expect(find.byType(AdaptiveGlass), findsOneWidget);
          expect(find.text('内容'), findsOneWidget);
        } else {
          expect(find.byType(BackdropFilter), findsOneWidget);
          expect(find.byType(MoeLiquidGlass), findsNothing);
          expect(
            tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
            MoeFrostedMaterial.surfaceFilter(
              brightness,
              sigma: MoeFrostedMaterial.blurSigmaForSetting(32),
              fill: 0.8,
            ),
          );
          expect(
            _surfaceMaterial(tester).color,
            MoeFrostedMaterial.surfaceTint(brightness, fill: 0.8),
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('explicit color stays a plain fill without blur', (tester) async {
    const color = Color(0x80123456);
    await tester.pumpWidget(
      _wrap(
        glassEnabled: true,
        child: const MoeContentSurface(color: color, child: Text('内容')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(_surfaceMaterial(tester).color, color);
  });

  for (final (name, highContrast, reduceTransparency) in [
    ('high contrast', true, false),
    ('reduce transparency', false, true),
  ]) {
    testWidgets('accessibility $name forces opaque without blur', (
      tester,
    ) async {
      for (final color in [null, const Color(0x80123456)]) {
        await tester.pumpWidget(
          _wrap(
            glassEnabled: true,
            highContrast: highContrast,
            reduceTransparency: reduceTransparency,
            child: MoeContentSurface(color: color, child: const Text('内容')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsNothing);
        expect(_surfaceMaterial(tester).color!.a, 1.0);
      }
    });
  }

  testWidgets('child TextField state survives blur and global mode toggles', (
    tester,
  ) async {
    MoeLiquidGlassService.setMockState(available: true);
    final mode = ValueNotifier(MoeSurfaceMaterial.solid);
    addTearDown(mode.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: mode,
        builder: (_, value, __) => _wrap(
          glassEnabled: value != MoeSurfaceMaterial.solid,
          liquid: value == MoeSurfaceMaterial.liquid,
          child: const MoeContentSurface(child: _Draft()),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '未保存的草稿');
    final original = tester.state(find.byType(_Draft));
    for (final value in [
      MoeSurfaceMaterial.frosted,
      MoeSurfaceMaterial.liquid,
      MoeSurfaceMaterial.solid,
    ]) {
      mode.value = value;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(_Draft)), same(original));
      expect(find.text('未保存的草稿'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('asymmetric borderRadius produces correct G2 path', (
    tester,
  ) async {
    const radius = BorderRadius.only(
      topLeft: Radius.circular(30),
      bottomRight: Radius.circular(10),
    );
    await tester.pumpWidget(
      _wrap(
        child: const SizedBox(
          width: 100,
          height: 100,
          child: MoeContentSurface(borderRadius: radius, child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final material = _surfaceMaterial(tester);
    expect(material.shape, isA<SmoothRectangleBorder>());
    expect(material.shape, moeG2Shape(borderRadius: radius));
    final rect = tester.getRect(find.byType(MoeContentSurface));
    final local = Rect.fromLTWH(0, 0, rect.width, rect.height);
    final path = (material.shape as SmoothRectangleBorder).getOuterPath(local);
    final expectedPath = moeG2Shape(borderRadius: radius).getOuterPath(local);
    expect(path.getBounds(), expectedPath.getBounds());
    for (final point in [
      const Offset(2, 2),
      const Offset(97, 97),
      const Offset(50, 50),
      const Offset(97, 3),
    ]) {
      expect(path.contains(point), expectedPath.contains(point));
    }
    expect(path.contains(const Offset(2, 2)), isFalse);
    expect(path.contains(const Offset(50, 50)), isTrue);
  });

  testWidgets('radius 0 has square corners', (tester) async {
    await tester.pumpWidget(
      _wrap(
        child: const SizedBox(
          width: 100,
          height: 60,
          child: MoeContentSurface(radius: 0, child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final material = _surfaceMaterial(tester);
    final rect = tester.getRect(find.byType(MoeContentSurface));
    final path = (material.shape as SmoothRectangleBorder).getOuterPath(
      Rect.fromLTWH(0, 0, rect.width, rect.height),
    );
    expect(path.contains(const Offset(0.5, 0.5)), isTrue);
    expect(path.getBounds(), Rect.fromLTWH(0, 0, rect.width, rect.height));
  });

  testWidgets('border and shadows share the clip and material shape', (
    tester,
  ) async {
    const border = BorderSide(color: Color(0xFF112233), width: 1.5);
    const shadows = [
      BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 4)),
    ];
    await tester.pumpWidget(
      _wrap(
        child: const SizedBox(
          width: 120,
          height: 80,
          child: MoeContentSurface(
            radius: 16,
            border: border,
            shadows: shadows,
            child: Text('内容'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final material = _surfaceMaterial(tester);
    final shape = material.shape as SmoothRectangleBorder;
    expect(shape.side, border);
    final clipper =
        tester
                .widget<ClipPath>(
                  find.descendant(
                    of: find.byType(MoeContentSurface),
                    matching: find.byType(ClipPath),
                  ),
                )
                .clipper
            as ShapeBorderClipper;
    expect(clipper.shape, material.shape);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(MoeContentSurface),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as ShapeDecoration;
    expect(decoration.shadows, shadows);
    expect(decoration.shape, moeG2Shape(radius: 16));
  });
}

class _Draft extends StatefulWidget {
  const _Draft();
  @override
  State<_Draft> createState() => _DraftState();
}

class _DraftState extends State<_Draft> {
  final controller = TextEditingController();
  final focus = FocusNode();
  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(controller: controller, focusNode: focus);
}
