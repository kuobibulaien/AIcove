import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_search_field.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'floating thickness reveals background at zero and increases gently dark=$dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(240, 160);
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        final samples = <int>[];
        for (final sigma in [0.0, 16.0, 32.0]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                extensions: [dark ? MoeColors.dark() : MoeColors.light()],
              ),
              home: MoeGlassTheme(
                enabled: true,
                useLiquidGlass: true,
                blurSigma: sigma,
                tintFill: sigma / kMaxGlassBlurSigma,
                child: RepaintBoundary(
                  key: key,
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: ColoredBox(color: Color(0xFF808080)),
                      ),
                      Positioned(
                        left: 20,
                        right: 20,
                        top: 20,
                        bottom: 20,
                        child: MoeFloatingSurface(
                          blurSigma: sigma,
                          shadows: const [],
                          useLiquid: false,
                          child: const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: ColoredBox(color: Color(0xFFFF0000)),
                            ),
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
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = (await tester.runAsync(() => boundary.toImage()))!;
          final bytes = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          int channel(int x, int y, [int c = 0]) =>
              bytes.getUint8((y * 240 + x) * 4 + c);
          samples.add(channel(60, 80));
          expect(channel(120, 80), 255);
          expect(
            channel(120, 80, 1),
            0,
            reason: 'Foreground stays sharp and untinted',
          );
          expect(channel(2, 2), 128, reason: 'The material remains clipped');
          if (sigma == 0) {
            expect(
              channel(60, 80),
              128,
              reason: 'Floating zero reveals the original background',
            );
            expect(find.byType(BackdropFilter), findsNothing);
          }
          image.dispose();
        }
        final half = (samples[1] - samples[0]).abs();
        final full = (samples[2] - samples[0]).abs();
        expect(
          half,
          greaterThan(3),
          reason: 'Thickness must visibly affect the tint',
        );
        expect(full, greaterThan(half));
        expect(
          full,
          lessThan(50),
          reason: 'Maximum must not become an opaque slab',
        );
      },
    );
  }

  testWidgets(
    'grouped search retains its readable material without an opaque fill',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MoeSurfaceGroup(
            child: Scaffold(body: MoeSearchField(onChanged: (_) {})),
          ),
        ),
      );
      expect(
        tester
            .widget<MoeFloatingSurface>(find.byType(MoeFloatingSurface))
            .baseline,
        MoeMaterialBaseline.background,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.fillColor,
        Colors.transparent,
      );
    },
  );
}
