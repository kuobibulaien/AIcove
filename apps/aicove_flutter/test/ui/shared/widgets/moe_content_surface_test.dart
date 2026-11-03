import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/effects/smooth_clip.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/moe_frosted_material.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

  testWidgets('solid mode is an opaque ink-tinted componentBackground', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(child: const MoeContentSurface(child: Text('内容'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    final color = _surfaceMaterial(tester).color!;
    expect(
      color,
      Color.alphaBlend(
        moeContentSurfaceInk(Brightness.light),
        MoeColors.light().componentBackground,
      ),
    );
    expect(color.a, 1);
    expect(color, isNot(MoeColors.light().componentBackground));
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
          final color = _surfaceMaterial(tester).color!;
          expect(
            color,
            Color.alphaBlend(
              moeContentSurfaceInk(brightness),
              MoeFrostedMaterial.surfaceTint(brightness, fill: 0.8),
            ),
          );
          // Frosted cards must never turn into a solid fill.
          expect(color.a, lessThan(1));
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

  for (final (glassEnabled, liquid) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets('sliver surface keeps rows lazy, blurs when translucent '
        'glass=$glassEnabled liquid=$liquid', (tester) async {
      await tester.pumpWidget(
        _wrap(
          glassEnabled: glassEnabled,
          liquid: liquid,
          child: CustomScrollView(
            slivers: [
              MoeSliverContentSurface(
                sliver: SliverList.builder(
                  itemCount: 1000,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 40, child: Text('row $i')),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsOneWidget);
      expect(find.text('row 999'), findsNothing);
      final blurs = tester.layers.whereType<BackdropFilterLayer>();
      expect(blurs, glassEnabled ? hasLength(1) : isEmpty);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (dark, liquid) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      'MoePageScaffold solid backdrop skips BackdropFilterLayer for content cards '
      'dark=$dark liquid=$liquid',
      (tester) async {
        MoeLiquidGlassService.setMockState(available: true);
        final colors = dark ? MoeColors.dark() : MoeColors.light();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              extensions: [colors],
            ),
            builder: (context, child) => MoeGlassTheme(
              enabled: true,
              useLiquidGlass: liquid,
              blurSigma: 16,
              tintFill: 0.5,
              child: child!,
            ),
            home: MoePageScaffold(
              body: ListView(
                children: [
                  const MoeContentSurface(child: Text('卡片一')),
                  const MoeContentSurface(child: Text('卡片二')),
                  SizedBox(
                    height: 120,
                    child: CustomScrollView(
                      slivers: [
                        MoeSliverContentSurface(
                          sliver: SliverList.list(
                            children: const [Text('列表项')],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('卡片一'), findsOneWidget);
        expect(find.text('卡片二'), findsOneWidget);
        expect(find.text('列表项'), findsOneWidget);
        expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'MoePageScaffold with wallpaper shares one BackdropKey across sibling cards '
    'and isolates nested cards',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          builder: (context, child) => MoeGlassTheme(
            enabled: true,
            blurSigma: 16,
            tintFill: 0.5,
            child: MoeWallpaperTheme(
              wallpaper: GlobalWallpaper.catnap,
              child: child!,
            ),
          ),
          home: const MoePageScaffold(
            body: Column(
              children: [
                MoeContentSurface(
                  key: ValueKey('card-1'),
                  child: MoeContentSurface(
                    key: ValueKey('nested-card'),
                    child: Text('嵌套卡片'),
                  ),
                ),
                MoeContentSurface(
                  key: ValueKey('card-2'),
                  child: Text('同级卡片二'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      BackdropFilter filterInside(Key surfaceKey) => tester.widget<BackdropFilter>(
        find
            .descendant(
              of: find.byKey(surfaceKey),
              matching: find.byType(BackdropFilter),
            )
            .first,
      );
      final card1Filter = filterInside(const ValueKey('card-1'));
      final card2Filter = filterInside(const ValueKey('card-2'));
      final nestedFilter = tester.widget<BackdropFilter>(
        find.descendant(
          of: find.byKey(const ValueKey('nested-card')),
          matching: find.byType(BackdropFilter),
        ),
      );
      expect(card1Filter.backdropGroupKey, isNotNull);
      expect(card2Filter.backdropGroupKey, same(card1Filter.backdropGroupKey));
      expect(nestedFilter.backdropGroupKey, isNull);
    },
  );

  testWidgets('solid backdrop content cards source rendered preview', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('WRITE_CONTENT_PREVIEW')) return;
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final loader = FontLoader('Preview')
        ..addFont(
          File(
            '/System/Library/Fonts/STHeiti Medium.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '${Platform.environment['HOME']}/dev-sdks/flutter-3.44.6/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    });

    MoeLiquidGlassService.setMockState(available: true);
    for (final (name, liquid, dark) in [
      ('frosted-light', false, false),
      ('liquid-light', true, false),
    ]) {
      final key = GlobalKey();
      final colors = dark ? MoeColors.dark() : MoeColors.light();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: 'Preview',
            brightness: dark ? Brightness.dark : Brightness.light,
            extensions: [colors],
          ),
          builder: (context, child) => MoeGlassTheme(
            enabled: true,
            useLiquidGlass: liquid,
            blurSigma: 16,
            tintFill: 0.5,
            child: child!,
          ),
          home: RepaintBoundary(
            key: key,
            child: MoePageScaffold(
              appBar: const MoeAppBar(
                title: '界面设置',
                showBackButton: true,
              ),
              body: ListView(
                padding: const EdgeInsets.fromLTRB(16, 80, 16, 24),
                children: [
                  const MoeSettingsGroup(
                    margin: EdgeInsets.zero,
                    children: [
                      MoeSettingsRow(
                        icon: Icons.palette_outlined,
                        label: '主题外观',
                        subtitle: '跟随系统浅色与深色切换',
                      ),
                      MoeSettingsRow(
                        icon: Icons.auto_awesome_outlined,
                        label: '表面材质',
                        subtitle: '纯色底面自动静态合成，保持通透质感',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  MoeContentSurface(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '分段切换预览',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        MoeSegmentedControl<String>(
                          value: liquid ? 'liquid' : 'frosted',
                          segments: const [
                            MoeSegment(value: 'solid', label: '纯色'),
                            MoeSegment(value: 'frosted', label: '毛玻璃'),
                            MoeSegment(value: 'liquid', label: '液态玻璃'),
                          ],
                          onChanged: (_) {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../.codex-temp/blur-opt-previews')
          ..createSync(recursive: true);
        await File(
          '${dir.path}/settings-$name-390.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
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
