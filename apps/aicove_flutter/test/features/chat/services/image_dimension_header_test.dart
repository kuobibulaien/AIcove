import 'dart:typed_data';

import 'package:aicove_flutter/src/features/chat/services/image_dimension_probe/image_dimension_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('encoded PNG and JPEG retain their individual dimensions', () {
    for (final bytes in [
      img.encodePng(img.Image(width: 23, height: 41)),
      img.encodeJpg(img.Image(width: 23, height: 41)),
    ]) {
      final dimensions = probeImageDimensionsFromBytes(bytes);
      expect(dimensions?.width, 23);
      expect(dimensions?.height, 41);
    }
  });

  test(
    'PNG header requires no image pixels and invalid input stays unknown',
    () {
      final png = img.encodePng(img.Image(width: 7, height: 13));
      expect(
        probeImageDimensionsFromBytes(
          Uint8List.sublistView(png, 0, 24),
        )?.height,
        13,
      );
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([1, 2, 3, 4]),
      ]) {
        expect(probeImageDimensionsFromBytes(bytes), isNull);
      }
    },
  );

  test('WebP VP8X, VP8L and VP8 frame headers retain intrinsic dimensions', () {
    Uint8List webp(String kind, List<int> payload) {
      final bytes = Uint8List(20 + payload.length + (payload.length & 1));
      bytes.setRange(0, 4, 'RIFF'.codeUnits);
      bytes.setRange(8, 12, 'WEBP'.codeUnits);
      bytes.setRange(12, 16, kind.codeUnits);
      ByteData.sublistView(bytes).setUint32(16, payload.length, Endian.little);
      bytes.setRange(20, 20 + payload.length, payload);
      return bytes;
    }

    final vp8l = ByteData(5)
      ..setUint8(0, 0x2f)
      ..setUint32(1, 22 | (40 << 14), Endian.little);
    for (final bytes in [
      webp('VP8X', [0, 0, 0, 0, 22, 0, 0, 40, 0, 0]),
      webp('VP8L', vp8l.buffer.asUint8List()),
      webp('VP8 ', [0, 0, 0, 0x9d, 1, 0x2a, 23, 0, 41, 0]),
    ]) {
      final dimensions = probeImageDimensionsFromBytes(bytes);
      expect((dimensions?.width, dimensions?.height), (23, 41));
      expect(
        probeImageDimensionsFromBytes(Uint8List.sublistView(bytes, 0, 19)),
        isNull,
      );
    }
  });
}
