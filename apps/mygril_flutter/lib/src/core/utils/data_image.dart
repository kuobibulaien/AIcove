import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

/// 工具方法：处理 data:image/...;base64,... 格式的本地图片数据。
/// 保持简单（KISS），避免在各组件中重复解析（DRY）。

// 说明：data:image 的 base64 解码是纯 CPU 工作，且 `MemoryImage` 的 key 与 bytes 的对象引用相关。
// 如果每次 build 都重新 base64Decode，会导致：
// 1) CPU 重复解码；2) ImageCache 无法命中（因为 bytes 不是同一个引用）；3) 页面切换/动画更容易掉帧。
// 这里做一个小型 LRU 缓存：同一段 data:image 在多处使用时复用同一份 Uint8List。
const int _kMaxDataImageCacheEntries = 32;
const int _kMaxDataImageCacheBytes = 12 * 1024 * 1024; // 12MB

final LinkedHashMap<String, Uint8List> _dataImageCache =
    LinkedHashMap<String, Uint8List>();
int _dataImageCacheBytes = 0;

Uint8List? decodeDataImage(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (!trimmed.startsWith('data:image')) return null;

  final cached = _dataImageCache[trimmed];
  if (cached != null) {
    // LRU：提升到队尾
    _dataImageCache.remove(trimmed);
    _dataImageCache[trimmed] = cached;
    return cached;
  }
  final comma = trimmed.indexOf(',');
  if (comma <= 0) return null;
  final base64Part = trimmed.substring(comma + 1);
  try {
    final decoded = Uint8List.fromList(base64Decode(base64Part));
    _putDataImageCache(trimmed, decoded);
    return decoded;
  } catch (_) {
    return null;
  }
}

bool isDataImage(String? value) => decodeDataImage(value) != null;

void _putDataImageCache(String key, Uint8List bytes) {
  // 单个 entry 超过总上限就不缓存，避免“一张超大图把缓存撑爆”。
  if (bytes.length > _kMaxDataImageCacheBytes) return;

  // 覆盖旧值时，先扣掉旧大小
  final existing = _dataImageCache.remove(key);
  if (existing != null) {
    _dataImageCacheBytes -= existing.length;
  }

  _dataImageCache[key] = bytes;
  _dataImageCacheBytes += bytes.length;

  // 按“条目数 + 总字节数”双阈值做淘汰
  while (_dataImageCache.length > _kMaxDataImageCacheEntries ||
      _dataImageCacheBytes > _kMaxDataImageCacheBytes) {
    final oldestKey = _dataImageCache.keys.first;
    final removed = _dataImageCache.remove(oldestKey);
    if (removed != null) {
      _dataImageCacheBytes -= removed.length;
    }
  }
}

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
