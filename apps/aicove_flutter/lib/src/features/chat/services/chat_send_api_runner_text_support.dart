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

  // 注意：不要在这里剥离 <image source="history">...</image>。
  // 该标签是内部图片上下文记录，可能出现在模型回显中；展示层 / stripPluginTags
  // 仅移除无属性的 inline 生图标签，带属性标签必须原样保留。
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

String _joinRoundTexts(List<String> texts) => texts
    .map((text) => text.trim())
    .where((text) => text.isNotEmpty)
    .join('\n');

/// 调过工具的回复按轮拆开的文字：每轮工具前的话术与最后一轮正文，去重后
/// 重复或空的轮留空串占位；全部为空时把合并后的兜底文字（工具完成摘要）
/// 放进最后一轮。
List<String> _replyRoundTexts({
  required Iterable<String> narratives,
  required String normalizedFinalText,
  required String mergedText,
}) {
  final seen = <String>{};
  String keep(String text) {
    final trimmed = text.trim();
    return trimmed.isNotEmpty && seen.add(trimmed) ? trimmed : '';
  }

  final texts = [
    for (final narrative in narratives) keep(narrative),
    keep(
      _looksLikeToolInstructionText(normalizedFinalText)
          ? ''
          : normalizedFinalText,
    ),
  ];
  if (texts.every((text) => text.isEmpty)) texts.last = mergedText;
  return texts;
}

/// 每轮文字单独过预设正则；只有一轮时就是原来的整段处理。
Future<List<SillyTavernRegexApplyResult>> _applyRoundRegex(
  List<String> texts,
  ApiConfig config,
) async => [
  for (final text in texts)
    await ChatSendApiRunner._presetRegexProcessor.applyToDisplayText(
      text: text,
      scripts: config.presetRegexScripts,
      authorized: config.presetRegexAuthorized,
    ),
];

SillyTavernRegexApplyResult _joinRegexResults(
  List<SillyTavernRegexApplyResult> rounds,
) => rounds.length == 1
    ? rounds.single
    : SillyTavernRegexApplyResult(
        text: _joinRoundTexts([for (final r in rounds) r.text]),
        warnings: [for (final r in rounds) ...r.warnings],
        traces: [for (final r in rounds) ...r.traces],
      );

/// 每轮文字单独过插件（插件只处理各自的标签，标签落在哪轮就在哪轮处理）；
/// 多轮时空轮不跑。
Future<List<PluginProcessResult>> _runRoundProcessors(
  List<SillyTavernRegexApplyResult> rounds,
  List<PluginResponseProcessor> processors,
) async => [
  for (final round in rounds)
    rounds.length > 1 && round.text.trim().isEmpty
        ? PluginProcessResult(processedText: '', events: const [])
        : await runResponseProcessors(
            processors,
            round.text,
            logTag: ChatSendApiRunner._logTag,
          ),
];

PluginProcessResult _joinPluginResults(List<PluginProcessResult> rounds) =>
    rounds.length == 1
    ? rounds.single
    : PluginProcessResult(
        processedText: _joinRoundTexts([
          for (final r in rounds) r.processedText,
        ]),
        events: [for (final r in rounds) ...r.events],
        contents: [for (final r in rounds) ...r.contents],
      );

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
  static const List<_HiddenStreamTagSpec> _hiddenTagSpecs =
      <_HiddenStreamTagSpec>[
    // 仅隐藏无属性的 inline 生图标签；带属性的 <image source="history"> 必须
    // 原样透传（由 _attributedImageDepth 深度计数保证其配对闭标签不被剥离）。
    _HiddenStreamTagSpec(openTagPrefix: '<image>', closeTag: '</image>'),
    _HiddenStreamTagSpec(openTagPrefix: '<think', closeTag: '</think>'),
    // 对话选项由右下角选项气泡展示（ADR0045），生成中不在气泡里闪现。
    _HiddenStreamTagSpec(openTagPrefix: '<options', closeTag: '</options>'),
    // 表情标签只去外壳，不隐藏成对写法的正文，也不等待自闭合标签的闭标签。
    _HiddenStreamTagSpec(
      openTagPrefix: '<${StickerTag.name}',
      closeTag: '</${StickerTag.name}>',
    ),
  ];

  String _pending = '';
  String? _activeCloseTag;

  /// 已透传、尚未配对关闭的「带属性 image 开标签」数量。
  /// 带属性开标签（如 <image source="history">）不进 hidden 状态而是原样透传，
  /// 其配对的 </image> 必须保留；只有深度为 0 时出现的 </image> 才是真孤立标签。
  int _attributedImageDepth = 0;
  static final RegExp _attributedImageOpenPattern =
      RegExp('<image[\\s/]', caseSensitive: false);

  void _emitVisible(StringBuffer output, String text) {
    if (text.isEmpty) return;
    _attributedImageDepth +=
        _attributedImageOpenPattern.allMatches(text).length;
    output.write(StickerTag.removeFrom(firstPartyContentTagScanner, text));
  }

  bool get _insideHiddenTag => _activeCloseTag != null;

  String consume(String delta) {
    if (delta.isEmpty) return '';
    _pending = '$_pending$delta';
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideHiddenTag) {
        final closeTag = _activeCloseTag!;
        final lowerPending = _pending.toLowerCase();
        final closeIndex = lowerPending.indexOf(closeTag);
        if (closeIndex < 0) {
          _pending = _retainTail(_pending, closeTag.length - 1);
          break;
        }
        _pending = _pending.substring(closeIndex + closeTag.length);
        _activeCloseTag = null;
        continue;
      }

      final lowerPending = _pending.toLowerCase();
      final hiddenTagMatch = _findNextHiddenTag(lowerPending);
      if (hiddenTagMatch != null) {
        final openIndex = hiddenTagMatch.openIndex;
        if (openIndex > 0) {
          _emitVisible(output, _pending.substring(0, openIndex));
        }
        final tagEndIndex = _findTagEnd(_pending, openIndex);
        if (tagEndIndex < 0) {
          _pending = _pending.substring(openIndex);
          break;
        }
        final opening = _pending.substring(openIndex, tagEndIndex + 1);
        final element = firstPartyContentTagScanner.scan(opening).first;
        _pending = _pending.substring(tagEndIndex + 1);
        if (!StickerTag.isElement(element)) {
          _activeCloseTag = hiddenTagMatch.closeTag;
        }
        continue;
      }

      // 关闭标签处理：配对（带属性 open 深度>0）的 </image> 原样保留；
      // 真正孤立的关闭标签（stray </image> / </think>）剥离。
      final hiddenCloseTagMatch = _findNextHiddenCloseTag(lowerPending);
      if (hiddenCloseTagMatch != null) {
        final closeIndex = hiddenCloseTagMatch.openIndex;
        final closeTag = hiddenCloseTagMatch.closeTag;
        final closeEnd = closeIndex + closeTag.length;
        _emitVisible(output, _pending.substring(0, closeIndex));
        if (closeTag == '</image>' && _attributedImageDepth > 0) {
          _attributedImageDepth--;
          output.write(_pending.substring(closeIndex, closeEnd));
        }
        _pending = _pending.substring(closeEnd);
        continue;
      }

      final partialPrefixLength =
          _findTrailingOpenTagPrefixLength(lowerPending);
      if (partialPrefixLength > 0) {
        final visibleEnd = _pending.length - partialPrefixLength;
        if (visibleEnd > 0) {
          _emitVisible(output, _pending.substring(0, visibleEnd));
        }
        _pending = _pending.substring(visibleEnd);
        break;
      }

      _emitVisible(output, _pending);
      _pending = '';
    }

    return output.toString();
  }

  // 属性里的 > 不结束标签；未收齐整个开标签时继续缓冲，不泄露属性文字。
  static int _findTagEnd(String text, int start) {
    String? quote;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (quote != null) {
        if (char == quote) quote = null;
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '>') {
        return i;
      }
    }
    return -1;
  }

  _HiddenTagMatch? _findNextHiddenTag(String lowerPending) {
    _HiddenTagMatch? firstMatch;
    for (final spec in _hiddenTagSpecs) {
      final index = _indexOfOpenTag(lowerPending, spec.openTagPrefix);
      if (index < 0) continue;
      if (firstMatch == null || index < firstMatch.openIndex) {
        firstMatch = _HiddenTagMatch(
          openIndex: index,
          closeTag: spec.closeTag,
        );
      }
    }
    return firstMatch;
  }

  /// 标签名必须完整匹配：`<think` 之后要紧跟 `>`、空白或 `/`，
  /// 否则 `<thinking>`、`<think_nya~>` 等预设标签会被误当成 `<think>`
  /// 一直等不到 `</think>` 而吞掉后文。前缀恰在末尾时先视为命中，等下一片。
  static int _indexOfOpenTag(String lowerPending, String prefix) {
    if (prefix.endsWith('>')) return lowerPending.indexOf(prefix);
    var from = 0;
    while (true) {
      final index = lowerPending.indexOf(prefix, from);
      if (index < 0) return -1;
      final next = index + prefix.length;
      if (next >= lowerPending.length ||
          const {' ', '\t', '\r', '\n', '/', '>'}
              .contains(lowerPending[next])) {
        return index;
      }
      from = index + 1;
    }
  }

  _HiddenTagMatch? _findNextHiddenCloseTag(String lowerPending) {
    _HiddenTagMatch? firstMatch;
    for (final spec in _hiddenTagSpecs) {
      final index = lowerPending.indexOf(spec.closeTag);
      if (index < 0) continue;
      if (firstMatch == null || index < firstMatch.openIndex) {
        firstMatch = _HiddenTagMatch(
          openIndex: index,
          closeTag: spec.closeTag,
        );
      }
    }
    return firstMatch;
  }

  int _findTrailingOpenTagPrefixLength(String value) {
    var maxLength = 0;
    for (final spec in _hiddenTagSpecs) {
      final openLength = _findTrailingPrefixLength(value, spec.openTagPrefix);
      if (openLength > maxLength) {
        maxLength = openLength;
      }
      // 关闭标签同样可能被 chunk 切开（如 '</im' + 'age>'），
      // 不保留会导致孤立闭标签识别不到而漏剥离。
      final closeLength = _findTrailingPrefixLength(value, spec.closeTag);
      if (closeLength > maxLength) {
        maxLength = closeLength;
      }
    }
    return maxLength;
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

class _HiddenStreamTagSpec {
  const _HiddenStreamTagSpec({
    required this.openTagPrefix,
    required this.closeTag,
  });

  final String openTagPrefix;
  final String closeTag;
}

class _HiddenTagMatch {
  const _HiddenTagMatch({
    required this.openIndex,
    required this.closeTag,
  });

  final int openIndex;
  final String closeTag;
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
