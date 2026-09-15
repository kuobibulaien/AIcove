import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/image_crop_dialog.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('crop initial layout size=$size scale=$scale',
          (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0ioAAAAASUVORK5CYII=');
        await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home:
                ImageCropDialog(imageBytes: bytes, fileName: 'synthetic.png')));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
