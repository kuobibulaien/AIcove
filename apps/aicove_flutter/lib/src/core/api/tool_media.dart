import 'dart:math';
import 'package:image/image.dart' as img;
import 'dart:convert';
import '../../features/plugins/domain/handlers/tool_output.dart';

const toolStepMarker = '_aicove_tool_step';
const toolImageSource = '_aicove_image_source';
const toolImageInfo = '_aicove_image_info';

Map<String, dynamic> toolImagePart(
  ToolImage image, {
  bool claude = false,
  bool gemini = false,
}) {
  final data = base64Encode(image.bytes);
  return {
    toolImageSource: image.source,
    toolImageInfo: {'width': image.width, 'height': image.height},
    if (claude) ...{
      'type': 'image',
      'source': {'type': 'base64', 'media_type': image.mimeType, 'data': data},
    } else if (gemini) ...{
      'inlineData': {'mimeType': image.mimeType, 'data': data},
    } else ...{
      'type': 'image_url',
      'image_url': {'url': 'data:${image.mimeType};base64,$data'},
    },
  };
}

List<Map<String, dynamic>> toolImageMessages(
  List<ToolImage> images, {
  String text = '以下是工具返回的图片：',
}) => buildToolImageMessages([
  for (final image in images) toolImagePart(image),
], text: text);

List<Map<String, dynamic>> buildToolImageMessages(
  List<Map<String, dynamic>> parts, {
  String text = '以下是工具返回的图片：',
}) => parts.isEmpty
    ? []
    : [
        {
          'role': 'user',
          toolStepMarker: true,
          'content': [
            {'type': 'text', 'text': text},
            ...parts,
          ],
        },
      ];

/// Immutable projections for the wire, logs and preset host. Runtime objects
/// keep their image payloads; only each outgoing copy is budgeted.
abstract final class ToolMedia {
  static bool _isImage(Map value) =>
      value['type'] == 'image_url' ||
      value['type'] == 'image' ||
      value.containsKey('inlineData') ||
      value.containsKey('inline_data');
  static (String, String)? _data(Map value) {
    final url = value['image_url'];
    if (url is Map && url['url'] is String) {
      final text = url['url'] as String;
      final match = RegExp(
        r'^data:([^;]+);base64,(.*)$',
        dotAll: true,
      ).firstMatch(text);
      if (match != null) return (match[1]!, match[2]!);
    }
    final source =
        value['source'] ?? value['inlineData'] ?? value['inline_data'];
    if (source is Map && source['data'] is String) {
      return (
        (source['media_type'] ??
                source['mimeType'] ??
                source['mime_type'] ??
                '')
            .toString(),
        source['data'] as String,
      );
    }
    return null;
  }

  static Object? _walk(
    Object? value,
    Object? Function(Map) image, {
    bool strip = false,
  }) {
    if (value is List) {
      return [for (final v in value) _walk(v, image, strip: strip)];
    }
    if (value is Map) {
      if (_isImage(value)) return image(value);
      return <String, dynamic>{
        for (final e in value.entries)
          if (!strip ||
              ![toolStepMarker, toolImageSource, toolImageInfo].contains(e.key))
            e.key.toString(): _walk(e.value, image, strip: strip),
      };
    }
    return value;
  }

  static Object? log(Object? value) => _walk(value, (v) {
    final data = _data(v);
    Object? dimensions = v[toolImageInfo];
    if (dimensions == null && data != null) {
      try {
        final bytes = base64Decode(data.$2);
        final info = img.findDecoderForData(bytes)?.startDecode(bytes);
        if (info != null) {
          dimensions = {'width': info.width, 'height': info.height};
        }
      } catch (_) {
        /* Unknown image metadata is logged without its payload. */
      }
    }
    return {
      'type': 'image_metadata',
      'mimeType': data?.$1,
      'bytes': data == null
          ? null
          : (data.$2.length * 3 ~/ 4) -
                (data.$2.endsWith('==')
                    ? 2
                    : data.$2.endsWith('=')
                    ? 1
                    : 0),
      'source': v[toolImageSource],
      'dimensions': dimensions,
    };
  }, strip: true);

  static String logJson(String json) {
    try {
      return jsonEncode(log(jsonDecode(json)));
    } on FormatException {
      return json;
    }
  }

  static List<Map<String, dynamic>> wire(
    List<Map<String, dynamic>> messages, {
    bool strip = true,
  }) {
    var count = 0, bytes = 0;
    final sizes = <int>[];
    _walk(messages, (v) {
      final d = _data(v);
      final size = d == null ? 0 : base64Decode(d.$2).length;
      sizes.add(size);
      count++;
      bytes += size;
      return v;
    });
    var omit = 0;
    while (count > 20 || bytes > 12 * 1024 * 1024) {
      bytes -= sizes[omit++];
      count--;
    }
    var seen = 0;
    final output =
        _walk(messages, (v) {
              if (seen++ < omit) {
                final text = omittedToolImage(
                  (v[toolImageSource] ?? 'tool').toString(),
                );
                return v.containsKey('inlineData') ||
                        v.containsKey('inline_data')
                    ? {'text': text}
                    : {'type': 'text', 'text': text};
              }
              return {
                for (final e in v.entries)
                  if (!strip ||
                      !([toolImageSource, toolImageInfo].contains(e.key)))
                    e.key.toString(): e.value,
              };
            }, strip: strip)
            as List;
    return output.map((m) => Map<String, dynamic>.from(m as Map)).toList();
  }
}

/// References are invocation-local and survive preset message reordering.
class PresetImageReferences {
  final _images = <String, Map>{};
  final _nonce =
      '${Random.secure().nextInt(1 << 32)}_${Random.secure().nextInt(1 << 32)}';
  Object? hide(Object? value) => ToolMedia._walk(value, (image) {
    final id = '__aicove_image_ref_${_nonce}_${_images.length}__';
    _images[id] = image;
    return {'type': 'text', 'text': id};
  });
  Object? restore(Object? value) {
    if (value is String) {
      if (!_images.keys.any(value.contains)) return value;
      final pattern = RegExp(_images.keys.map(RegExp.escape).join('|'));
      final parts = <Object?>[];
      var start = 0;
      for (final match in pattern.allMatches(value)) {
        if (match.start > start) {
          parts.add({
            'type': 'text',
            'text': value.substring(start, match.start),
          });
        }
        parts.add(_images[match[0]]);
        start = match.end;
      }
      if (start < value.length) {
        parts.add({'type': 'text', 'text': value.substring(start)});
      }
      return parts;
    }
    if (value is List) return [for (final v in value) ..._restoredPart(v)];
    if (value is Map) {
      if (value['type'] == 'text' && value['text'] is String) {
        final restored = restore(value['text']);
        if (restored is List) return restored;
      }
      return {
        for (final e in value.entries) e.key.toString(): restore(e.value),
      };
    }
    return value;
  }

  List<Object?> _restoredPart(Object? original) {
    final result = restore(original);
    final contentPart =
        original is String || (original is Map && original['type'] == 'text');
    return contentPart && result is List ? result : [result];
  }
}
