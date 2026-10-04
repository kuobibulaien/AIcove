import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/ui/shared/widgets/index.dart';
import 'package:aicove_flutter/src/ui/theme/moe_frosted_material.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

void main() {
  test('blurSigmaForSetting maps the 10..100% range onto the thin recipe', () {
    expect(MoeFrostedMaterial.blurSigmaForSetting(0), 2);
    expect(MoeFrostedMaterial.blurSigmaForSetting(3.2), 2);
    expect(MoeFrostedMaterial.blurSigmaForSetting(16), 10);
    expect(MoeFrostedMaterial.blurSigmaForSetting(32), 20);
    expect(MoeFrostedMaterial.blurSigmaForSetting(100), 20);
    expect(MoeFrostedMaterial.blurSigmaForSetting(-8), 2);
  });

  test('tint follows the fill and stays below popup opacity', () {
    for (final brightness in Brightness.values) {
      final clear = MoeFrostedMaterial.surfaceTint(brightness, fill: 0.1);
      final medium = MoeFrostedMaterial.surfaceTint(brightness, fill: 0.5);
      final heavy = MoeFrostedMaterial.surfaceTint(brightness, fill: 1);
      expect(clear.a, lessThan(medium.a));
      expect(medium.a, lessThan(heavy.a));
      expect(heavy.a, lessThan(0.8));
      expect(MoeFrostedMaterial.surfaceTint(brightness, fill: 0).a, 0);
      final faint = MoeFrostedMaterial.surfaceTint(brightness, fill: 0.05);
      expect(faint.a, greaterThan(0));
      expect(faint.a, lessThan(clear.a));
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('frosted strength pixels match the shared recipe $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(240, 180);
      addTearDown(tester.view.reset);
      final key = GlobalKey();

      Future<ByteData> render(Widget surface) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: RepaintBoundary(
              key: key,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _Backdrop()),
                  ),
                  Positioned(
                    left: 20,
                    top: 20,
                    width: 200,
                    height: 140,
                    child: surface,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = (await tester.runAsync(() => boundary.toImage()))!;
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        image.dispose();
        expect(tester.takeException(), isNull);
        return bytes;
      }

      const content = Center(
        child: SizedBox.square(
          dimension: 10,
          child: ColoredBox(color: Colors.red),
        ),
      );
      final regionChecksums = <double, int>{};
      final strengths = {0.0: 2.0, 3.2: 2.0, 16.0: 10.0, 32.0: 20.0};
      for (final MapEntry(key: sigma, value: expectedSigma)
          in strengths.entries) {
        final reference = await render(
          ClipRect(
            child: BackdropFilter(
              filter: MoeFrostedMaterial.surfaceFilter(
                brightness,
                sigma: expectedSigma,
              ),
              child: ColoredBox(
                color: MoeFrostedMaterial.surfaceTint(
                  brightness,
                  fill: sigma / kMaxGlassBlurSigma,
                ),
                child: content,
              ),
            ),
          ),
        );
        for (final baseline in [
          MoeMaterialBaseline.component,
          MoeMaterialBaseline.background,
        ]) {
          for (final liquid in [false, true]) {
            final actual = await render(
              MoeGlassTheme(
                enabled: true,
                blurSigma: sigma,
                tintFill: sigma / kMaxGlassBlurSigma,
                child: liquid
                    ? MoeLiquidGlass(
                        radius: 28,
                        baseline: baseline,
                        border: BorderSide.none,
                        shadows: const [],
                        child: content,
                      )
                    : MoeFloatingSurface(
                        baseline: baseline,
                        border: BorderSide.none,
                        shadows: const [],
                        child: content,
                      ),
              ),
            );
            var checksum = 0;
            // Exclude the host's intentionally different corner and border shape.
            for (var y = 55; y < 125; y++) {
              for (var x = 55; x < 185; x++) {
                final offset = (y * 240 + x) * 4;
                checksum += actual.getUint32(offset);
                for (var c = 0; c < 4; c++) {
                  expect(
                    actual.getUint8(offset + c),
                    closeTo(reference.getUint8(offset + c), 1),
                    reason:
                        'Recipe parity at $x,$y, sigma=$sigma, liquid=$liquid',
                  );
                }
              }
            }
            if (baseline == MoeMaterialBaseline.component && !liquid) {
              regionChecksums[sigma] = checksum;
            }
          }
        }
      }
      // Blur floors at 10%, but the tint fill may still go fully clear.
      expect(regionChecksums[0], isNot(regionChecksums[3.2]));
      expect(regionChecksums[0], isNot(regionChecksums[16]));
      expect(regionChecksums[0], isNot(regionChecksums[32]));
      expect(regionChecksums[3.2], isNot(regionChecksums[16]));
    });
  }

  testWidgets(
    'frosted keeps the blur floor at every strength and solid removes all filters',
    (tester) async {
      for (final enabled in [true, false]) {
        for (final sigma in [0.0, 3.2, 32.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: MoeGlassTheme(
                enabled: enabled,
                blurSigma: sigma,
                child: const MoeFloatingSurface(child: Text('Content')),
              ),
            ),
          );
          expect(
            find.byType(BackdropFilter),
            enabled ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets('frosted still degrades under reduce transparency', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MoeGlassTheme(
          enabled: true,
          blurSigma: 32,
          child: GlassAccessibilityScope(
            reduceTransparency: true,
            child: MoeFloatingSurface(child: Text('Content')),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _Backdrop extends CustomPainter {
  const _Backdrop();
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 16) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 16, size.height),
        Paint()
          ..color = (x / 16).round().isEven
              ? const Color(0xFF35A795)
              : const Color(0xFFE27291),
      );
    }
  }

  @override
  bool shouldRepaint(_Backdrop oldDelegate) => false;
}
