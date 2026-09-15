import 'dart:io';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // The dependency assumes its own package root when FLUTTER_TEST is set.
    // Alias the already compiled shaders inside the generated test bundle.
    for (final name in [
      'liquid_glass_render.frag',
      'liquid_glass_geometry_blended.frag',
      'lightweight_glass.frag',
      'interactive_indicator.frag',
      'progressive_blur.frag',
    ]) {
      final target = File('build/unit_test_assets/shaders/$name');
      await target.parent.create(recursive: true);
      await File(
        'build/unit_test_assets/packages/liquid_glass_widgets/shaders/$name',
      ).copy(target.path);
    }
    await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    if (const bool.fromEnvironment('WRITE_ALIGNMENT_QA')) {
      for (final entry in {
        'AlignmentCapture': '/System/Library/Fonts/STHeiti Medium.ttc',
        'MaterialIcons':
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final font = FontLoader(entry.key)
          ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView));
        await font.load();
      }
    }
  });
  testWidgets(
    'floating glass follows a translated ancestor without rebuilding content',
    (tester) async {
      MoeLiquidGlassService.setMockState(available: true);
      addTearDown(() => MoeLiquidGlassService.setMockState(available: false));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 400);
      addTearDown(tester.view.reset);
      final position = ValueNotifier(Offset.zero);
      addTearDown(position.dispose);
      final root = GlobalKey();
      final panel = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [MoeColors.dark()]),
          home: RepaintBoundary(
            key: root,
            child: ColoredBox(
              color: const Color(0xff607d8b),
              child: Stack(
                children: [
                  Positioned(
                    left: 60,
                    top: 60,
                    child: ValueListenableBuilder<Offset>(
                      valueListenable: position,
                      builder: (_, offset, child) =>
                          Transform.translate(offset: offset, child: child),
                      child: MoeLiquidGlass(
                        key: panel,
                        width: 180,
                        height: 90,
                        baseline: MoeMaterialBaseline.text,
                        blurSigma: 3.52,
                        shadows: const [],
                        border: BorderSide.none,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var frame = 0; frame < 6; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
      Future<ui.Image> capture() async =>
          (root.currentContext!.findRenderObject() as RenderRepaintBoundary)
              .toImage();
      await tester.runAsync(() async {
        (await capture()).dispose();
      });
      position.value = const Offset(120, 90);
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(() async {
          (await capture()).dispose();
        });
      }
      await tester.pump();
      await tester.runAsync(() async {
        final image = await capture();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final box = panel.currentContext!.findRenderObject() as RenderBox;
        final sample = box.localToGlobal(const Offset(150, 45));
        final i = (sample.dy.round() * image.width + sample.dx.round()) * 4;
        expect(
          bytes.getUint8(i + 1),
          lessThan(115),
          reason: 'Glass tint must move with the floating panel',
        );
        image.dispose();
      });
    },
    // Opt-in reproducer: retained shader coordinates still lag ancestor translation.
    // Keep this separate from passing layout coverage until the renderer is fixed.
    skip:
        !ui.ImageFilter.isShaderFilterSupported ||
        !const bool.fromEnvironment('RUN_KNOWN_LIQUID_MOTION'),
  );

  for (final refreshBeforePaint in [false, true]) {
    testWidgets(
      'scrolling premium glass aligns on its first moved frame refresh=$refreshBeforePaint',
      (tester) async {
        MoeLiquidGlassService.setMockState(available: true);
        addTearDown(
          () => MoeLiquidGlassService.setMockState(available: false),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(600, 400);
        addTearDown(tester.view.reset);
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final root = GlobalKey();
        final panel = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(extensions: [MoeColors.dark()]),
            home: RepaintBoundary(
              key: root,
              child: ColoredBox(
                color: const Color(0xff607d8b),
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.only(
                    left: 60,
                    top: 120,
                    right: 360,
                  ),
                  children: [
                    MoeLiquidGlass(
                      key: panel,
                      width: 180,
                      height: 90,
                      baseline: MoeMaterialBaseline.text,
                      blurSigma: 3.52,
                      shadows: const [],
                      border: BorderSide.none,
                      child: const SizedBox.expand(),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump();
        }
        const samplePoints = [
          Offset(30, 45),
          Offset(90, 45),
          Offset(150, 45),
        ];
        final box = panel.currentContext!.findRenderObject() as RenderBox;
        Future<List<List<int>>> sampleRgb(ui.Image image) async {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          return samplePoints.map((p) {
            final g = box.localToGlobal(p);
            final i = (g.dy.round() * image.width + g.dx.round()) * 4;
            return [
              bytes.getUint8(i),
              bytes.getUint8(i + 1),
              bytes.getUint8(i + 2),
            ];
          }).toList();
        }

        await tester.runAsync(() async {
          final image =
              await (root.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final rgb = await sampleRgb(image);
          image.dispose();
          print(
            '[scroll-regression refresh=$refreshBeforePaint] baseline rgb=$rgb',
          );
          for (final t in rgb) {
            expect(t[1], lessThan(115));
          }
        });
        controller.jumpTo(90);
        if (refreshBeforePaint) {
          final seen = Set<RenderObject>.identity();
          void mark(RenderObject ro) {
            if (seen.add(ro)) {
              ro.markNeedsPaint();
              ro.visitChildren(mark);
            }
          }

          mark(box);
        }
        await tester.pump();
        expect(box.localToGlobal(Offset.zero), const Offset(60, 30));
        await tester.runAsync(() async {
          final image =
              await (root.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final rgb = await sampleRgb(image);
          print(
            '[scroll-regression refresh=$refreshBeforePaint] moved rgb=$rgb',
          );
          if (const bool.fromEnvironment('WRITE_ALIGNMENT_QA')) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '../../scratch/liquid-motion-20260916/scroll-regression-refresh-$refreshBeforePaint.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
          for (final t in rgb) {
            expect(
              t[1],
              lessThan(115),
              reason: '布局已移动但glass shade未同步',
            );
          }
        });
      },
      skip:
          !ui.ImageFilter.isShaderFilterSupported ||
          !const bool.fromEnvironment('RUN_KNOWN_LIQUID_MOTION'),
    );
  }
}
