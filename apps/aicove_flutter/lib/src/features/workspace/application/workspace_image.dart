import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../../plugins/domain/handlers/tool_output.dart';

Future<ToolImage?> prepareWorkspaceImage(Uint8List bytes, String source) =>
    Isolate.run(() {
      try {
        final decoder = img.findDecoderForData(bytes);
        if (decoder == null) return null;
        var image = decoder.decode(bytes);
        if (image == null) return null;
        if (image.width > 1568 || image.height > 1568) {
          image = img.copyResize(
            image,
            width: image.width >= image.height ? 1568 : null,
            height: image.height > image.width ? 1568 : null,
          );
        }
        var encoded = Uint8List.fromList(img.encodePng(image));
        var mime = 'image/png';
        if (encoded.length > 2 * 1024 * 1024) {
          mime = 'image/jpeg';
          for (final quality in [90, 75, 60, 40, 20]) {
            encoded = Uint8List.fromList(
              img.encodeJpg(image, quality: quality),
            );
            if (encoded.length <= 2 * 1024 * 1024) break;
          }
        }
        return encodedWorkspaceImage(
          mimeType: mime,
          bytes: encoded,
          source: source,
          width: image.width,
          height: image.height,
        );
      } catch (_) {
        return null;
      }
    });

/// The final encoded-byte boundary, shared by lossless and JPEG candidates.
ToolImage? encodedWorkspaceImage({
  required Uint8List bytes,
  required String mimeType,
  required String source,
  required int width,
  required int height,
}) => bytes.length > 2 * 1024 * 1024
    ? null
    : ToolImage(
        bytes: bytes,
        mimeType: mimeType,
        source: source,
        width: width,
        height: height,
      );
