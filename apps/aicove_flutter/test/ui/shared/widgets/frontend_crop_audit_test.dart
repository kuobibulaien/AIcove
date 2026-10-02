import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/image_crop_dialog.dart';
import '../../../helpers/release_source_preview.dart';

void main() {
  for (final width in [320.0, 1000.0]) {
    for (final confirm in [false, true]) {
      testWidgets(
        'crop returns image only on confirmation width=$width confirm=$confirm',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 768));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final bytes = await _syntheticImage(tester);
          Uint8List? result;
          var returned = false;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('open crop'),
                    onPressed: () async {
                      result = await Navigator.of(context).push<Uint8List>(
                        MaterialPageRoute(
                          builder: (_) => ImageCropDialog(
                            imageBytes: bytes,
                            fileName: 'synthetic.png',
                          ),
                        ),
                      );
                      returned = true;
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open crop'));
          await tester.pumpAndSettle();
          await _waitForImage(tester);
          expect(
            find.byWidgetPredicate(
              (widget) => widget is RawImage && widget.image != null,
            ),
            findsWidgets,
          );
          await tester.tap(find.byIcon(confirm ? Icons.check : Icons.close));
          for (var attempt = 0; attempt < 20 && !returned; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          await tester.pumpAndSettle();
          expect(returned, isTrue);
          expect(find.byType(ImageCropDialog), findsNothing);
          expect(tester.takeException(), isNull);
          if (confirm) {
            expect(result, isNotNull);
            final dimensions = (await tester.runAsync(() async {
              final codec = await ui.instantiateImageCodec(result!);
              final frame = await codec.getNextFrame();
              final dimensions = Size(
                frame.image.width.toDouble(),
                frame.image.height.toDouble(),
              );
              frame.image.dispose();
              codec.dispose();
              return dimensions;
            }))!;
            expect(dimensions.width, dimensions.height);
            expect(dimensions.width, inExclusiveRange(0, 128));
          } else {
            expect(result, isNull);
          }
        },
      );
    }
  }
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('crop initial layout size=$size scale=$scale', (
        tester,
      ) async {
        await loadReleasePreviewFonts(tester);
        final previewKey = GlobalKey();
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = await _syntheticImage(tester);
        await tester.pumpWidget(
          RepaintBoundary(
            key: previewKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                fontFamily: captureReleaseSourcePreview
                    ? 'ReleasePreview'
                    : null,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ImageCropDialog(
                imageBytes: bytes,
                fileName: 'synthetic.png',
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await _waitForImage(tester);
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await saveReleaseSourcePreview(
          tester,
          previewKey,
          'crop-${size.width.toInt()}-$scale',
        );
      });
    }
  }
}

Future<Uint8List> _syntheticImage(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var row = 0; row < 4; row++) {
        for (var column = 0; column < 4; column++) {
          canvas.drawRect(
            Rect.fromLTWH(column * 32.0, row * 32.0, 32, 32),
            Paint()
              ..color = (row + column).isEven
                  ? const Color(0xff62b5ce)
                  : const Color(0xffe4ad74),
          );
        }
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(128, 128);
      try {
        final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
        return encoded!.buffer.asUint8List();
      } finally {
        image.dispose();
        picture.dispose();
      }
    }))!;

Future<void> _waitForImage(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find
        .byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        )
        .evaluate()
        .isNotEmpty)
      return;
  }
}
