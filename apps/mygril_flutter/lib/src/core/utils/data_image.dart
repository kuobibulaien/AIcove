import 'dart:convert';
import 'dart:typed_data';

/// 工具方法：处理 data:image/...;base64,... 格式的本地图片数据。
/// 保持简单（KISS），避免在各组件中重复解析（DRY）。

Uint8List? decodeDataImage(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (!trimmed.startsWith('data:image')) return null;
  final comma = trimmed.indexOf(',');
  if (comma <= 0) return null;
  final base64Part = trimmed.substring(comma + 1);
  try {
    return Uint8List.fromList(base64Decode(base64Part));
  } catch (_) {
    return null;
  }
}

bool isDataImage(String? value) => decodeDataImage(value) != null;

String buildDataImage(
  Uint8List bytes, {
  String? mimeType,
  String? fileName,
}) {
  final mime = mimeType ?? _inferMimeType(fileName);
  final encoded = base64Encode(bytes);
  return 'data:$mime;base64,$encoded';
}

String _inferMimeType(String? fileName) {
  final lower = (fileName ?? '').toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  return 'image/png';
}
