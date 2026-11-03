import 'dart:typed_data';

import 'probe_types.dart';

/// Reads intrinsic dimensions without decompressing pixels or allocating a codec.
/// Unknown and truncated formats remain unknown for the background probe.
ImageDimensions? probeImageDimensionsFromBytes(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  bool tag(int at, String value) =>
      at + value.length <= bytes.length &&
      List.generate(
        value.length,
        (i) => bytes[at + i] == value.codeUnitAt(i),
      ).every((same) => same);
  ImageDimensions? dimensions(int width, int height) => width > 0 && height > 0
      ? ImageDimensions(
          width: width,
          height: height,
          hitSource: ImageDimensionProbeSource.bytes,
        )
      : null;
  if (bytes.length >= 24 && tag(0, '\x89PNG\r\n\x1a\n') && tag(12, 'IHDR')) {
    return dimensions(data.getUint32(16), data.getUint32(20));
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var at = 2;
    while (at + 1 < bytes.length) {
      if (bytes[at++] != 0xff) return null;
      while (at < bytes.length && bytes[at] == 0xff) {
        at++;
      }
      if (at >= bytes.length) return null;
      final marker = bytes[at++];
      if (marker == 0xda || marker == 0xd9) return null;
      if (marker == 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
      if (at + 2 > bytes.length) return null;
      final length = data.getUint16(at);
      if (length < 2 || at + length > bytes.length) return null;
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          !{0xc4, 0xc8, 0xcc}.contains(marker)) {
        if (length < 8) return null;
        return dimensions(data.getUint16(at + 5), data.getUint16(at + 3));
      }
      at += length;
    }
  }
  if (bytes.length >= 20 && tag(0, 'RIFF') && tag(8, 'WEBP')) {
    var at = 12;
    while (at + 8 <= bytes.length) {
      final length = data.getUint32(at + 4, Endian.little);
      final start = at + 8;
      if (start + length > bytes.length) return null;
      if (tag(at, 'VP8X') && length >= 10) {
        int u24(int p) => bytes[p] | bytes[p + 1] << 8 | bytes[p + 2] << 16;
        return dimensions(1 + u24(start + 4), 1 + u24(start + 7));
      }
      if (tag(at, 'VP8L') && length >= 5 && bytes[start] == 0x2f) {
        final bits = data.getUint32(start + 1, Endian.little);
        return dimensions(1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff));
      }
      if (tag(at, 'VP8 ') && length >= 10 && tag(start + 3, '\x9d\x01\x2a')) {
        return dimensions(
          data.getUint16(start + 6, Endian.little) & 0x3fff,
          data.getUint16(start + 8, Endian.little) & 0x3fff,
        );
      }
      at = start + length + (length & 1);
    }
  }
  return null;
}
