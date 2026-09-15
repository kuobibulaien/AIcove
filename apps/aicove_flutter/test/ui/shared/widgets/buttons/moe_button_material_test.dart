import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer_more_panel.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('WRITE_BUTTON_QA');
  const shaders = bool.fromEnvironment('RUN_BUTTON_SHADER_QA');
  setUpAll(() async {
    if (shaders) {
      for (final name in [
        'liquid_glass_final_render.frag',
        'liquid_glass_geometry_blended.frag',
      ]) {
        final target = File('build/unit_test_assets/shaders/$name');
        await target.parent.create(recursive: true);
        await File(
          'build/unit_test_assets/packages/liquid_glass_widgets/shaders/$name',
        ).copy(target.path);
      }
      await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    }
    if (!capture) return;
    for (final entry in {
      'ButtonCapture': '/System/Library/Fonts/STHeiti Medium.ttc',
      'MaterialIcons':
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  tearDown(() => MoeLiquidGlassService.setMockState(available: false));
  for (final dark in [false, true]) {
    for (final mode in MoeSurfaceMaterial.values) {
      for (final sigma in [0.0, 16.0, 32.0]) {
        testWidgets('buttons $mode dark=$dark sigma=$sigma', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(420, 790);
          addTearDown(tester.view.reset);
          MoeLiquidGlassService.setMockState(available: true);
          final colors = dark ? MoeColors.dark() : MoeColors.light();
          final boundaryKey = GlobalKey();
          var taps = 0;
          await tester.pumpWidget(
            MaterialApp(
              theme: withMoeInteractionTheme(
                ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  fontFamily: capture ? 'ButtonCapture' : null,
                  extensions: [colors],
                ),
              ),
              home: MoeGlassTheme(
                enabled: mode != MoeSurfaceMaterial.solid,
                useLiquidGlass: mode == MoeSurfaceMaterial.liquid,
                blurSigma: sigma,
                child: Scaffold(
                  body: RepaintBoundary(
                    key: boundaryKey,
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
                                      const Color(0xFF15537A),
                                      const Color(0xFF111822),
                                      const Color(0xFF784949),
                                    ]
                                  : [
                                      const Color(0xFF77B6D8),
                                      const Color(0xFFF3DBD4),
                                      const Color(0xFFA6C9A6),
                                    ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 50,
                          top: 80,
                          child: Container(
                            width: 90,
                            height: 260,
                            color: colors.text.withValues(alpha: 0.2),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            children: [
                              const SizedBox(height: 12),
                              Text(
                                '${dark ? "深色" : "浅色"} · ${mode.label} · 厚度 ${(sigma / 32 * 100).round()}',
                                style: TextStyle(
                                  color: colors.text,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 22),
                              MoeFloatingSurface(
                                child: ComposerMorePanel(
                                  onAction: (_) => taps++,
                                ),
                              ),
                              const SizedBox(height: 18),
                              Wrap(
                                spacing: 12,
                                children: [
                                  FilledButton(
                                    onPressed: () {},
                                    child: const Text('添加'),
                                  ),
                                  TextButton(
                                    onPressed: () {},
                                    child: const Text('编辑'),
                                  ),
                                  IconButton(
                                    onPressed: () {},
                                    style: withoutHoverFeedback(
                                      IconButton.styleFrom(
                                        shape: const CircleBorder(),
                                        backgroundColor: colors.accentColor,
                                      ),
                                    ),
                                    icon: const Icon(Icons.arrow_upward),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              MoePrimaryButton(
                                label: '确认',
                                onPressed: () => taps++,
                              ),
                              const SizedBox(height: 12),
                              MoeSecondaryButton(
                                label: '取消',
                                onPressed: () => taps++,
                              ),
                              const SizedBox(height: 12),
                              MoeTileButton(
                                label: '功能入口',
                                icon: Icons.settings_outlined,
                                onTap: () => taps++,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  MoeIconButton(
                                    icon: Icons.add,

                                    onTap: () => taps++,
                                  ),
                                  const SizedBox(width: 16),
                                  MoeIconButton(
                                    icon: Icons.close,
                                    onTap: () => taps++,
                                  ),
                                  const SizedBox(width: 16),
                                  const MoeSecondaryButton(
                                    label: '不可用',
                                    onPressed: null,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (shaders && mode == MoeSurfaceMaterial.liquid) {
            for (var frame = 0; frame < 6; frame++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 40)),
              );
              await tester.pump();
            }
          }
          expect(tester.takeException(), isNull);
          if (mode == MoeSurfaceMaterial.solid) {
            expect(find.byType(BackdropFilter), findsNothing);
            expect(find.byType(AdaptiveGlass), findsNothing);
          } else if (mode == MoeSurfaceMaterial.liquid) {
            expect(find.byType(AdaptiveGlass), findsWidgets);
          } else {
            expect(
              find.byType(BackdropFilter),
              sigma == 0 ? findsNothing : findsWidgets,
            );
          }
          for (final type in [
            MoePrimaryButton,
            MoeSecondaryButton,
            MoeTileButton,
            MoeIconButton,
            MoreActionTile,
            FilledButton,
            TextButton,
            IconButton,
          ]) {
            for (final button in find.byType(type).evaluate()) {
              final finder = find.byWidget(button.widget);
              expect(
                find.descendant(
                  of: finder,
                  matching: find.byType(MoeFloatingSurface),
                ),
                findsOneWidget,
              );
            }
          }
          final primaryTint = tester.widget<MoeButtonSurface>(
            find.descendant(
              of: find.byType(MoePrimaryButton),
              matching: find.byType(MoeButtonSurface),
            ),
          );
          final tintDecoration =
              tester
                      .widget<AnimatedContainer>(
                        find.descendant(
                          of: find.byWidget(primaryTint),
                          matching: find.byType(AnimatedContainer),
                        ),
                      )
                      .decoration
                  as BoxDecoration;
          expect(tintDecoration.color!.a, lessThanOrEqualTo(0.29));
          expect(tintDecoration.color!.a, greaterThan(0.2));
          await tester.tap(find.text('确认'));
          await tester.tap(find.text('相册'));
          await tester.tap(find.text('不可用'));
          await tester.pumpAndSettle();
          expect(taps, 2);
          expect(tester.takeException(), isNull);
          if (capture) {
            await tester.runAsync(() async {
              final boundary =
                  boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(
                pixelRatio: tester.view.devicePixelRatio,
              );
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.codex-temp/button-material-20260914/${shaders ? "shader-" : ""}${mode.name}-${dark ? "dark" : "light"}-${sigma.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }
}
