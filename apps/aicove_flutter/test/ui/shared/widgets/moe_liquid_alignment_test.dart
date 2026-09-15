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
  for (final scale in [1.0, 0.9, 1.2]) {
    testWidgets(
      'nested premium glass alignment scale=$scale',
      (tester) async {
        MoeLiquidGlassService.setMockState(available: true);
        addTearDown(() => MoeLiquidGlassService.setMockState(available: false));
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1000, 800);
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: const bool.fromEnvironment('WRITE_ALIGNMENT_QA')
                  ? 'AlignmentCapture'
                  : null,
              extensions: [MoeColors.dark()],
            ),
            home: MoeGlassTheme(
              enabled: true,
              useLiquidGlass: true,
              blurSigma: 3.52,
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: const Color(0xFF607D8B),
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(30, 70, 30, 60),
                      child: MoeFloatingSurface(
                        baseline: MoeMaterialBaseline.background,
                        child: Column(
                          children: [
                            const SizedBox(height: 24),
                            MoeSearchField(onChanged: (_) {}),
                          ],
                        ),
                      ),
                    ),
                  ),
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
        final search = tester.renderObject<RenderBox>(
          find.descendant(
            of: find.byType(MoeSearchField),
            matching: find.byType(MoeLiquidGlass),
          ),
        );
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          double luminance(Offset local) {
            final point = search.localToGlobal(local) * 2;
            final index =
                (point.dy.round() * image.width + point.dx.round()) * 4;
            return bytes.getUint8(index) * .2126 +
                bytes.getUint8(index + 1) * .7152 +
                bytes.getUint8(index + 2) * .0722;
          }

          final background = luminance(
            Offset(search.size.width * .2, search.size.height + 20),
          );
          for (final fraction in [.25, .5, .75]) {
            expect(
              luminance(
                Offset(search.size.width * .2, search.size.height * fraction),
              ),
              lessThan(background - 5),
              reason:
                  'The text material must fill the search field, not shift outside its bounds',
            );
          }
          image.dispose();
        });
        expect(
          tester.widget<TextField>(find.byType(TextField)).decoration!.border,
          InputBorder.none,
        );
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('WRITE_ALIGNMENT_QA')) {
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.codex-temp/search-alignment/impeller-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'search');
        expect(find.text('search'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      skip: !ui.ImageFilter.isShaderFilterSupported,
    );
  }
  for (final enabled in [true, false]) {
    testWidgets(
      'custom oval outline follows glass shape enabled=$enabled',
      (tester) async {
        MoeLiquidGlassService.setMockState(available: true);
        addTearDown(() => MoeLiquidGlassService.setMockState(available: false));
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: MoeLiquidGlass(
                  enabled: enabled,
                  shape: const LiquidOval(),
                  border: const BorderSide(color: Colors.red, width: 3),
                  shadows: const [],
                  width: 180,
                  height: 80,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          if (const bool.fromEnvironment('WRITE_ALIGNMENT_QA')) {
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            final file = File(
              '../../.codex-temp/liquid-audit/oval-$enabled.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png.buffer.asUint8List());
          }
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final path = const LiquidOval().getOuterPath(
            const Rect.fromLTWH(0, 0, 180, 80),
          );
          var misplacedBorderPixels = 0;
          var visibleBorderPixels = 0;
          for (var y = 0; y < 80; y++) {
            for (var x = 0; x < 180; x++) {
              final i = (y * 180 + x) * 4;
              if (data.getUint8(i) > 200 &&
                  data.getUint8(i + 1) < 100 &&
                  data.getUint8(i + 3) > 200) {
                visibleBorderPixels++;
              }
              if (data.getUint8(i) > 200 &&
                  data.getUint8(i + 1) < 100 &&
                  data.getUint8(i + 3) > 200 &&
                  !path.contains(Offset(x + .5, y + .5))) {
                misplacedBorderPixels++;
              }
            }
          }
          expect(
            visibleBorderPixels,
            greaterThan(200),
            reason: 'The requested border must not disappear',
          );
          expect(
            misplacedBorderPixels,
            lessThan(8),
            reason: 'No rectangular outline outside oval glass',
          );
          image.dispose();
        });
      },
      skip: !ui.ImageFilter.isShaderFilterSupported,
    );
  }
}
