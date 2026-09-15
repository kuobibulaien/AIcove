import 'dart:io';
import 'package:aicove_flutter/src/ui/shared/effects/frosted_glass_card.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  setUp(() => MoeLiquidGlassService.setMockState(available: false));
  tearDown(() => MoeLiquidGlassService.setMockState());
  const capture = bool.fromEnvironment('WRITE_LAYER_QA');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('LayerCapture')
      ..addFont(
        File(
          '/System/Library/Fonts/STHeiti Medium.ttc',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await icons.load();
  });
  test('every layer responds continuously and preserves its tint order', () {
    for (final colors in [MoeColors.light(), MoeColors.dark()]) {
      final previous = <double>[-1, -1, -1];
      for (var value = 0; value <= 100; value++) {
        final layers = [
          MoeMaterialBaseline.none,
          MoeMaterialBaseline.background,
          MoeMaterialBaseline.text,
        ];
        final alphas = layers
            .map(
              (b) => colors.glassTintForSigma(value / 100 * 32, baseline: b).a,
            )
            .toList();
        expect(alphas[0], lessThan(alphas[1]));
        expect(alphas[1], lessThan(alphas[2]));
        for (var i = 0; i < layers.length; i++) {
          expect(alphas[i], greaterThan(previous[i]));
          previous[i] = alphas[i];
        }
      }
    }
  });
  testWidgets(
    'legacy card follows the global slider instead of its local default',
    (tester) async {
      for (final sigma in [0.0, 16.0, 32.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MoeGlassTheme(
              useLiquidGlass: true,
              enabled: true,
              blurSigma: sigma,
              child: const SizedBox(
                width: 200,
                height: 160,
                child: FrostedGlassCard(child: Text('内容')),
              ),
            ),
          ),
        );
        final surface = tester.widget<MoeFloatingSurface>(
          find.byType(MoeFloatingSurface),
        );
        expect(surface.blurSigma, sigma);
        expect(surface.baseline, MoeMaterialBaseline.text);
      }
    },
  );
  for (final dark in [false, true]) {
    for (final width in [420.0, 1000.0]) {
      testWidgets(
        'live global thickness preserves input dark=$dark width=$width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 600);
          addTearDown(tester.view.reset);
          final sigma = ValueNotifier(0.0);
          addTearDown(sigma.dispose);
          final key = GlobalKey();
          final colors = dark ? MoeColors.dark() : MoeColors.light();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: capture ? 'LayerCapture' : null,
                extensions: [colors],
              ),
              home: Scaffold(
                body: ValueListenableBuilder<double>(
                  valueListenable: sigma,
                  builder: (_, value, __) => MoeGlassTheme(
                    useLiquidGlass: true,
                    enabled: true,
                    blurSigma: value,
                    child: RepaintBoundary(
                      key: key,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: dark
                                    ? [
                                        const Color(0xFF195574),
                                        const Color(0xFF1A202A),
                                        const Color(0xFF754A54),
                                      ]
                                    : [
                                        const Color(0xFF8BBADB),
                                        const Color(0xFFF1D4CA),
                                        const Color(0xFF9BB9A2),
                                      ],
                              ),
                            ),
                          ),
                          Positioned(
                            left: width * 0.25,
                            top: 100,
                            bottom: 0,
                            child: Container(
                              width: 60,
                              color: colors.text.withValues(alpha: 0.15),
                            ),
                          ),
                          Center(
                            child: SizedBox(
                              width: 380,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '全局厚度 ${(value / 32 * 100).round()}',
                                      style: TextStyle(
                                        color: colors.text,
                                        fontSize: 18,
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    const MoeFloatingSurface(
                                      padding: EdgeInsets.all(16),
                                      shadows: [],
                                      child: Text('悬浮组件 · 可以全透明'),
                                    ),
                                    const SizedBox(height: 20),
                                    MoeFloatingSurface(
                                      baseline: MoeMaterialBaseline.background,
                                      padding: const EdgeInsets.all(20),
                                      child: MoeSurfaceGroup(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '背景 · 保留薄底',
                                              style: TextStyle(
                                                color: colors.text,
                                                fontSize: 16,
                                              ),
                                            ),
                                            const SizedBox(height: 18),
                                            MoeSearchField(
                                              hintText: '搜索 · 更厚一层',
                                              onChanged: (_) {},
                                            ),
                                            const SizedBox(height: 16),
                                            const MoeTextField(
                                              hint: '输入框 · 更厚一层',
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final input = find.descendant(
            of: find.byType(MoeTextField),
            matching: find.byType(TextField),
          );
          await tester.enterText(input, '调节时保留草稿');
          final editable = tester.widget<EditableText>(
            find.descendant(
              of: find.byType(MoeTextField),
              matching: find.byType(EditableText),
            ),
          );
          for (final value in [0.0, 16.0, 32.0]) {
            sigma.value = value;
            await tester.pumpAndSettle();
            expect(editable.controller.text, '调节时保留草稿');
            expect(editable.focusNode.hasFocus, isTrue);
            final surfaces = tester
                .widgetList<MoeFloatingSurface>(find.byType(MoeFloatingSurface))
                .toList();
            expect(surfaces.map((s) => s.baseline), [
              MoeMaterialBaseline.none,
              MoeMaterialBaseline.background,
              MoeMaterialBaseline.text,
              MoeMaterialBaseline.text,
            ]);
            for (final surface in surfaces) {
              final material = tester.widget<Material>(
                find
                    .descendant(
                      of: find.byWidget(surface),
                      matching: find.byType(Material),
                    )
                    .first,
              );
              expect(
                material.color!.a,
                closeTo(
                  colors.glassTintForSigma(value, baseline: surface.baseline).a,
                  0.0001,
                ),
              );
            }
            expect(tester.takeException(), isNull);
            if (capture) {
              await tester.runAsync(() async {
                final boundary =
                    key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../../.codex-temp/material-layers/${dark ? "dark" : "light"}-${width.toInt()}-${value.toInt()}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        },
      );
    }
  }
}
