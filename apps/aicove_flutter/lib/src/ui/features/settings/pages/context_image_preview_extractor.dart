import 'dart:convert';

enum ContextImagePreviewKind {
  dataUri,
  remoteUrl,
  fileUrl,
}

class ContextImagePreview {
  const ContextImagePreview({
    required this.kind,
    required this.value,
    required this.identityKey,
  });

  final ContextImagePreviewKind kind;
  final String value;
  final String identityKey;

  bool get isDataImage => kind == ContextImagePreviewKind.dataUri;
}

class ContextImagePreviewBatch {
  const ContextImagePreviewBatch({
    required this.items,
    required this.totalCount,
    required this.hasMore,
  });

  final List<ContextImagePreview> items;
  final int totalCount;
  final bool hasMore;

  static const empty = ContextImagePreviewBatch(
    items: <ContextImagePreview>[],
    totalCount: 0,
    hasMore: false,
  );
}

ContextImagePreviewBatch extractContextImagePreviewsFromRequestBody(
  String? rawRequestBody, {
  int limit = 4,
}) {
  if (rawRequestBody == null) return ContextImagePreviewBatch.empty;
  final raw = rawRequestBody.trim();
  if (raw.isEmpty) return ContextImagePreviewBatch.empty;
  final safeLimit = limit < 1 ? 1 : limit;

  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return ContextImagePreviewBatch.empty;
  }

  final items = <ContextImagePreview>[];
  final seen = <String>{};
  var totalCount = 0;
  var hasMore = false;

  void addPreview(ContextImagePreview preview) {
    final dedupeKey = '${preview.kind.name}:${preview.identityKey}';
    if (!seen.add(dedupeKey)) return;
    totalCount += 1;
    if (items.length < safeLimit) {
      items.add(preview);
      return;
    }
    hasMore = true;
  }

  ContextImagePreview? buildFromUrl(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return null;
    if (_looksLikeDataImage(value)) {
      return ContextImagePreview(
        kind: ContextImagePreviewKind.dataUri,
        value: value,
        identityKey: _fingerprint(value),
      );
    }
    if (_looksLikeRemoteUrl(value)) {
      return ContextImagePreview(
        kind: ContextImagePreviewKind.remoteUrl,
        value: value,
        identityKey: value,
      );
    }
    if (_looksLikeFileUrl(value)) {
      return ContextImagePreview(
        kind: ContextImagePreviewKind.fileUrl,
        value: value,
        identityKey: value,
      );
    }
    return null;
  }

  bool visit(dynamic node, {bool imageHint = false}) {
    if (hasMore) return true;

    if (node is List) {
      for (final item in node) {
        if (visit(item, imageHint: imageHint)) return true;
      }
      return false;
    }

    if (node is! Map) return false;
    final map = node.cast<String, dynamic>();
    final type = (map['type'] ?? '').toString().toLowerCase();
    final currentImageHint = imageHint ||
        type == 'image' ||
        type == 'image_url' ||
        type == 'input_image' ||
        map.containsKey('image_url') ||
        map.containsKey('inlineData') ||
        map.containsKey('inline_data') ||
        map.containsKey('source');

    final imageUrl = map['image_url'];
    if (imageUrl is Map) {
      final nestedUrl = imageUrl['url']?.toString();
      final preview = buildFromUrl(nestedUrl);
      if (preview != null) addPreview(preview);
    } else if (imageUrl is String) {
      final preview = buildFromUrl(imageUrl);
      if (preview != null) addPreview(preview);
    }

    if (currentImageHint && map['url'] is String) {
      final preview = buildFromUrl(map['url'] as String);
      if (preview != null) addPreview(preview);
    }

    if (currentImageHint) {
      final sourceRaw = map['source'];
      if (sourceRaw is Map) {
        final source = sourceRaw.cast<String, dynamic>();
        final sourceType = (source['type'] ?? '').toString().toLowerCase();
        if (sourceType == 'base64') {
          final mediaType = _readMimeType(source);
          final data = (source['data'] ?? '').toString().trim();
          if (data.isNotEmpty) {
            final preview = buildFromUrl('data:$mediaType;base64,$data');
            if (preview != null) addPreview(preview);
          }
        }
      }

      final inlineRaw = map['inlineData'] ?? map['inline_data'];
      if (inlineRaw is Map) {
        final inline = inlineRaw.cast<String, dynamic>();
        final mediaType = _readMimeType(inline);
        final data = (inline['data'] ?? '').toString().trim();
        if (data.isNotEmpty) {
          final preview = buildFromUrl('data:$mediaType;base64,$data');
          if (preview != null) addPreview(preview);
        }
      }
    }

    for (final value in map.values) {
      if (visit(value, imageHint: currentImageHint)) return true;
    }
    return false;
  }

  visit(decoded);
  return ContextImagePreviewBatch(
    items: List<ContextImagePreview>.unmodifiable(items),
    totalCount: totalCount,
    hasMore: hasMore,
  );
}

String _readMimeType(Map<String, dynamic> map) {
  final candidates = <String>[
    map['media_type']?.toString() ?? '',
    map['mime_type']?.toString() ?? '',
    map['mimeType']?.toString() ?? '',
  ];
  for (final candidate in candidates) {
    final normalized = candidate.trim();
    if (normalized.isNotEmpty) return normalized;
  }
  return 'image/jpeg';
}

String _fingerprint(String value) {
  if (value.length <= 160) return value;
  return '${value.length}:${value.substring(0, 80)}:${value.substring(value.length - 80)}';
}

bool _looksLikeDataImage(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('data:image') && lower.contains(';base64,');
}

bool _looksLikeRemoteUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('https://') || lower.startsWith('http://');
}

bool _looksLikeFileUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('file://');
}
