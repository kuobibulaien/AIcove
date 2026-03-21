part of 'chat_send_api_runner.dart';

String _sanitizeAssistantText(String text) {
  var cleaned = text;
  if (cleaned.trim().isEmpty) return cleaned.trim();

  cleaned = cleaned.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
    '',
  );
  cleaned = cleaned.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');

  cleaned = cleaned.replaceAllMapped(
    RegExp(r'\[(图片|image)\s*:\s*[^\]]*?\]', caseSensitive: false),
    (_) => '<image></image>',
  );
  cleaned = cleaned.replaceAllMapped(
    RegExp(r'<image>\s*</image>', caseSensitive: false),
    (_) => '<image></image>',
  );

  cleaned = cleaned.replaceAll(
    ChatRequestMessageBuilder.nonVisionImageContextRegex,
    '',
  );
  cleaned = cleaned.replaceAll(
    RegExp(
      '${RegExp.escape(ChatSendApiRunner._stableDrawImageReviewPrefix)}[^\\r\\n]*(?:\\r?\\n)?',
    ),
    '',
  );
  cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  return cleaned.trim();
}

String _stripStandaloneImagePlaceholders(String text) {
  var cleaned = text;
  if (cleaned.trim().isEmpty) return cleaned.trim();

  cleaned = cleaned.replaceAll(
    RegExp(
      r'^[ \t]*(?:<image>\s*</image>|\[(?:图片|image)(?:\s*:[^\]]*)?\])[ \t]*(?:\r?\n)?',
      caseSensitive: false,
      multiLine: true,
    ),
    '',
  );

  cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return cleaned.trim();
}

bool _looksLikeToolInstructionText(String text) {
  if (text.trim().isEmpty) return false;
  if (text.contains('<execute_tool>')) return true;
  if (RegExp(r'"action"\s*:\s*"[a-zA-Z_][a-zA-Z0-9_]*"').hasMatch(text)) {
    return true;
  }
  if (RegExp(r'"action_input"\s*:').hasMatch(text)) return true;
  if (RegExp(
    r'^\s*\[(prompt|negative_prompt|size)\]\s*$',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(text)) {
    return true;
  }
  if (RegExp(r'\bdraw_image\s*\(', caseSensitive: false).hasMatch(text)) {
    return true;
  }
  return false;
}

String _normalizeRoundNarrativeText(String text) {
  final sanitized = _sanitizeAssistantText(text);
  if (sanitized.isEmpty) return '';
  return _stripStandaloneImagePlaceholders(sanitized);
}

String _mergeNarrativeTexts(List<String> texts) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final text in texts) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) continue;
    if (seen.add(trimmed)) {
      normalized.add(trimmed);
    }
  }
  return normalized.join('\n');
}

bool _shouldSuppressToolStatusText({
  required String text,
  required int generatedImageCount,
  required bool hasAudio,
  required int toolCallCount,
}) {
  if (toolCallCount <= 0) return false;
  if (generatedImageCount <= 0 && !hasAudio) return false;

  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return false;
  return lines.every(_isToolStatusLine);
}

bool _isToolStatusLine(String line) {
  final normalized = line.trim();
  if (normalized.isEmpty) return false;

  final lowered = normalized.toLowerCase();
  if (RegExp(
    r'^(image generated and sent|images generated and sent \(\d+ total\)|tool call executed|audio output was also handled)[.!]?$',
  ).hasMatch(lowered)) {
    return true;
  }

  return RegExp(
    r'^(图片(?:已)?生成并发送|工具调用已执行|音频输出(?:也)?已处理)[。.!！]?$',
  ).hasMatch(normalized);
}

String _buildToolCompletionSummary({
  required int generatedImageCount,
  required bool hasAudio,
}) {
  final chunks = <String>[];
  if (generatedImageCount > 0) {
    chunks.add(
      generatedImageCount == 1
          ? 'Image generated and sent.'
          : 'Images generated and sent ($generatedImageCount total).',
    );
  }
  if (hasAudio) {
    chunks.add('Audio output was also handled.');
  }
  if (chunks.isEmpty) {
    return 'Tool call executed.';
  }
  return chunks.join('\n');
}

List<Map<String, dynamic>> _sanitizeMessagesForNonVisionModel(
  List<Map<String, dynamic>> messages,
) {
  final sanitized = <Map<String, dynamic>>[];
  var removedImageParts = 0;

  for (final message in messages) {
    final map = Map<String, dynamic>.from(message);
    final role = (map['role'] ?? '').toString().toLowerCase();

    final contentResult = _sanitizeNodeRemovingImageParts(map['content']);
    removedImageParts += contentResult.removed;
    if (map.containsKey('content')) {
      map['content'] = contentResult.value;
    }

    final partsResult = _sanitizeNodeRemovingImageParts(map['parts']);
    removedImageParts += partsResult.removed;
    if (map.containsKey('parts')) {
      map['parts'] = partsResult.value;
    }

    if (map['content'] is List && (map['content'] as List).isEmpty) {
      if (role == 'assistant' &&
          (map.containsKey('tool_calls') || map.containsKey('function_call'))) {
        map['content'] = null;
      } else {
        map['content'] = '';
      }
    }
    if (map['parts'] is List && (map['parts'] as List).isEmpty) {
      map['parts'] = <Map<String, dynamic>>[];
    }

    sanitized.add(map);
  }

  if (removedImageParts > 0) {
    AppLogger.info(
        ChatSendApiRunner._logTag, 'Removed image parts for non-vision model',
        metadata: {
          'removedImageParts': removedImageParts,
          'messageCount': messages.length,
        });
  }
  return sanitized;
}

_SanitizeResult _sanitizeNodeRemovingImageParts(dynamic node) {
  if (node == null) {
    return const _SanitizeResult(value: null, removed: 0);
  }

  if (node is List) {
    final list = <dynamic>[];
    var removed = 0;
    for (final item in node) {
      final child = _sanitizeNodeRemovingImageParts(item);
      removed += child.removed;
      if (!child.dropCurrentNode) {
        list.add(child.value);
      }
    }
    return _SanitizeResult(value: list, removed: removed);
  }

  if (node is Map) {
    final map = <String, dynamic>{};
    node.forEach((key, value) {
      map[key.toString()] = value;
    });

    if (_isImagePartMap(map)) {
      return const _SanitizeResult(
        value: null,
        removed: 1,
        dropCurrentNode: true,
      );
    }

    var removed = 0;
    final normalized = <String, dynamic>{};
    for (final entry in map.entries) {
      final child = _sanitizeNodeRemovingImageParts(entry.value);
      removed += child.removed;
      if (entry.value is List &&
          child.value is List &&
          (child.value as List).isEmpty) {
        normalized[entry.key] = child.value;
        continue;
      }
      normalized[entry.key] = child.value;
    }

    return _SanitizeResult(value: normalized, removed: removed);
  }

  return _SanitizeResult(value: node, removed: 0);
}

bool _isImagePartMap(Map<String, dynamic> part) {
  final type = (part['type'] ?? '').toString().toLowerCase();
  if (type == 'image_url' || type == 'input_image' || type == 'image') {
    return true;
  }

  if (part.containsKey('image_url')) return true;

  if (part.containsKey('inlineData')) {
    final inline = part['inlineData'];
    if (inline is Map) {
      final mime = inline['mimeType']?.toString().toLowerCase() ?? '';
      if (mime.isEmpty || mime.startsWith('image/')) {
        return true;
      }
    } else {
      return true;
    }
  }

  if (part.containsKey('fileData')) {
    final file = part['fileData'];
    if (file is Map) {
      final mime = file['mimeType']?.toString().toLowerCase() ?? '';
      if (mime.startsWith('image/')) {
        return true;
      }
    }
  }

  return false;
}

class _VisibleAssistantStreamFilter {
  static const String _imageOpenTagPrefix = '<image';
  static const String _imageCloseTag = '</image>';

  String _pending = '';
  bool _insideImageTag = false;

  String consume(String delta) {
    if (delta.isEmpty) return '';
    _pending = '$_pending$delta';
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideImageTag) {
        final lowerPending = _pending.toLowerCase();
        final closeIndex = lowerPending.indexOf(_imageCloseTag);
        if (closeIndex < 0) {
          _pending = _retainTail(_pending, _imageCloseTag.length - 1);
          break;
        }
        _pending = _pending.substring(closeIndex + _imageCloseTag.length);
        _insideImageTag = false;
        continue;
      }

      final lowerPending = _pending.toLowerCase();
      final openIndex = lowerPending.indexOf(_imageOpenTagPrefix);
      if (openIndex >= 0) {
        if (openIndex > 0) {
          output.write(_pending.substring(0, openIndex));
        }
        final tagEndIndex = _pending.indexOf('>', openIndex);
        if (tagEndIndex < 0) {
          _pending = _pending.substring(openIndex);
          break;
        }
        _pending = _pending.substring(tagEndIndex + 1);
        _insideImageTag = true;
        continue;
      }

      final partialPrefixLength =
          _findTrailingPrefixLength(lowerPending, _imageOpenTagPrefix);
      if (partialPrefixLength > 0) {
        final visibleEnd = _pending.length - partialPrefixLength;
        if (visibleEnd > 0) {
          output.write(_pending.substring(0, visibleEnd));
        }
        _pending = _pending.substring(visibleEnd);
        break;
      }

      output.write(_pending);
      _pending = '';
    }

    return output.toString();
  }

  String _retainTail(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return value.substring(value.length - maxLength);
  }

  int _findTrailingPrefixLength(String value, String prefix) {
    final maxLength =
        value.length < prefix.length ? value.length : prefix.length;
    for (var length = maxLength; length > 0; length--) {
      if (prefix.startsWith(value.substring(value.length - length))) {
        return length;
      }
    }
    return 0;
  }
}

class _SanitizeResult {
  const _SanitizeResult({
    required this.value,
    required this.removed,
    this.dropCurrentNode = false,
  });

  final dynamic value;
  final int removed;
  final bool dropCurrentNode;
}
