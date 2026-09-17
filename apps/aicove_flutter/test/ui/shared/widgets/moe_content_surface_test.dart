import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
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
      blurSigma: 16,
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

  for (final mode in MoeSurfaceMaterial.values) {
    testWidgets('default surface stays opaque in $mode', (tester) async {
      MoeLiquidGlassService.setMockState(available: true);
      await tester.pumpWidget(
        _wrap(
          glassEnabled: mode != MoeSurfaceMaterial.solid,
          liquid: mode == MoeSurfaceMaterial.liquid,
          child: const MoeContentSurface(child: Text('内容')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(AdaptiveGlass), findsNothing);
      expect(find.byType(MoeLiquidGlass), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('honors componentBackground dark=$dark', (tester) async {
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        _wrap(dark: dark, child: const MoeContentSurface(child: Text('内容'))),
      );
      await tester.pumpAndSettle();
      expect(_surfaceMaterial(tester).color, colors.componentBackground);
    });
  }

  testWidgets('explicit color alpha is honored without blur', (tester) async {
    const color = Color(0x80123456);
    await tester.pumpWidget(
      _wrap(
        glassEnabled: true,
        child: const MoeContentSurface(color: color, child: Text('内容')),
      ),
    );
    await tester.pumpAndSettle();
    expect(_surfaceMaterial(tester).color, color);
  });

  testWidgets('blurSigma 6 creates exactly one backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        glassEnabled: true,
        child: const MoeContentSurface(
          blurSigma: 6,
          color: Color(0x80123456),
          child: Text('内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    final filter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(filter.filter.toString(), contains('6.0'));
    expect(_surfaceMaterial(tester).color, const Color(0x80123456));
  });

  testWidgets('blur sigma clamps to kMaxContentSurfaceBlurSigma', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        glassEnabled: true,
        child: const MoeContentSurface(blurSigma: 24, child: Text('内容')),
      ),
    );
    await tester.pumpAndSettle();
    final filter = tester.widget<BackdropFilter>(
      find.byType(BackdropFilter),
    );
    expect(filter.filter.toString(), contains('$kMaxContentSurfaceBlurSigma'));
  });

  for (final (name, highContrast, reduceTransparency, glassEnabled) in [
    ('high contrast', true, false, true),
    ('reduce transparency', false, true, true),
    ('global glass disabled', false, false, false),
  ]) {
    testWidgets('blur suppressed under $name', (tester) async {
      await tester.pumpWidget(
        _wrap(
          glassEnabled: glassEnabled,
          highContrast: highContrast,
          reduceTransparency: reduceTransparency,
          child: const MoeContentSurface(
            blurSigma: 6,
            color: Color(0x80123456),
            child: Text('内容'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(_surfaceMaterial(tester).color!.a, 1.0);
    });
  }

  for (final (name, highContrast, reduceTransparency) in [
    ('high contrast', true, false),
    ('reduce transparency', false, true),
  ]) {
    testWidgets('accessibility $name forces opaque without blur', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          glassEnabled: true,
          highContrast: highContrast,
          reduceTransparency: reduceTransparency,
          child: const MoeContentSurface(
            color: Color(0x80123456),
            child: Text('内容'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(_surfaceMaterial(tester).color!.a, 1.0);
    });
  }

  testWidgets('global glass disabled alone keeps explicit alpha', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        glassEnabled: false,
        child: const MoeContentSurface(
          color: Color(0x80123456),
          child: Text('内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(_surfaceMaterial(tester).color, const Color(0x80123456));
  });

  testWidgets('child TextField state survives blur and global mode toggles', (
    tester,
  ) async {
    MoeLiquidGlassService.setMockState(available: true);
    final mode = ValueNotifier(MoeSurfaceMaterial.solid);
    final blur = ValueNotifier(0.0);
    addTearDown(mode.dispose);
    addTearDown(blur.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: blur,
        builder: (_, sigma, __) => ValueListenableBuilder(
          valueListenable: mode,
          builder: (_, value, __) => _wrap(
            glassEnabled: value != MoeSurfaceMaterial.solid,
            liquid: value == MoeSurfaceMaterial.liquid,
            child: MoeContentSurface(blurSigma: sigma, child: const _Draft()),
          ),
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
      for (final sigma in [6.0, 0.0]) {
        blur.value = sigma;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(_Draft)), same(original));
        expect(find.text('未保存的草稿'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }
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
          child: MoeContentSurface(
            borderRadius: radius,
            child: Text('内容'),
          ),
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
    final expectedPath = moeG2Shape(
      borderRadius: radius,
    ).getOuterPath(local);
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
    expect(
      path.getBounds(),
      Rect.fromLTWH(0, 0, rect.width, rect.height),
    );
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
