import 'kaomoji_parser.dart';

/// 消息格式化配置
///
/// 注意：分段功能是纯前端展示逻辑，不影响消息存储。
/// 消息在数据库中保持完整，分段仅在 UI 渲染时处理。
class MessageFormatConfig {
  /// 是否启用分段显示
  final bool enableChunking;

  /// 是否过滤标点
  final bool filterPunctuation;

  /// 分段标点列表（用空格分隔便于编辑）
  final List<String> chunkPunctuations;

  /// 过滤标点列表
  final List<String> filterPunctuations;

  /// 表情包发送概率 (0.0 - 1.0，0表示关闭)
  final double stickerProbability;

  /// 最小分段长度（短于此长度的段会被合并）
  final int minSegmentLength;

  /// 是否保护引号内容不被拆分
  final bool protectQuotes;

  const MessageFormatConfig({
    this.enableChunking = true, // 默认开启分段
    this.filterPunctuation = false,
    this.chunkPunctuations = const ['。', '！', '？', '，', '、', '；', '…'],
    this.filterPunctuations = const ['。', '，', '、', '；', '…', ',', ';'],
    this.stickerProbability = 0.3,
    this.minSegmentLength = 5,
    this.protectQuotes = true,
  });

  MessageFormatConfig copyWith({
    bool? enableChunking,
    bool? filterPunctuation,
    List<String>? chunkPunctuations,
    List<String>? filterPunctuations,
    double? stickerProbability,
    int? minSegmentLength,
    bool? protectQuotes,
  }) {
    return MessageFormatConfig(
      enableChunking: enableChunking ?? this.enableChunking,
      filterPunctuation: filterPunctuation ?? this.filterPunctuation,
      chunkPunctuations: chunkPunctuations ?? this.chunkPunctuations,
      filterPunctuations: filterPunctuations ?? this.filterPunctuations,
      stickerProbability: stickerProbability ?? this.stickerProbability,
      minSegmentLength: minSegmentLength ?? this.minSegmentLength,
      protectQuotes: protectQuotes ?? this.protectQuotes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableChunking': enableChunking,
      'filterPunctuation': filterPunctuation,
      'chunkPunctuations': chunkPunctuations,
      'filterPunctuations': filterPunctuations,
      'stickerProbability': stickerProbability,
      'minSegmentLength': minSegmentLength,
      'protectQuotes': protectQuotes,
    };
  }

  factory MessageFormatConfig.fromJson(Map<String, dynamic> json) {
    return MessageFormatConfig(
      enableChunking: json['enableChunking'] as bool? ?? true, // 默认开启
      filterPunctuation: json['filterPunctuation'] as bool? ?? false,
      chunkPunctuations:
          (json['chunkPunctuations'] as List<dynamic>?)?.cast<String>() ??
              const ['。', '！', '？', '，', '、', '；', '…'],
      filterPunctuations:
          (json['filterPunctuations'] as List<dynamic>?)?.cast<String>() ??
              const ['。', '，', '、', '；', '…', ',', ';'],
      stickerProbability:
          (json['stickerProbability'] as num?)?.toDouble() ?? 0.3,
      minSegmentLength: json['minSegmentLength'] as int? ?? 5,
      protectQuotes: json['protectQuotes'] as bool? ?? true,
    );
  }
}

/// 消息格式化器
///
/// 负责消息的格式化处理,包括:
/// - 消息分段和智能分割
/// - 颜文字保护
/// - 引号内容保护
/// - 短句智能合并
/// - 标点符号过滤
class MessageFormatter {
  // 引号对匹配正则：成对的中英日引号、书名号、方括号
  static final _quotePattern = RegExp(
    r'([「].*?[」]|[『].*?[』]|["].*?["]|[''].*?['']|[《].*?[》]|[【].*?[】]|"[^"]*")',
  );

  // 逗号类标点（句意未完成，应向后合并）
  static const _commaPuncts = {'，', ',', '、', '；', ';'};

  // 句号类标点（句意完整）
  static const _periodPuncts = {'。', '！', '？', '!', '?', '…'};

  /// 格式化并分段文本
  ///
  /// Args:
  ///   text: 原始文本
  ///   config: 格式化配置
  ///
  /// Returns:
  ///   分段后的文本列表
  static List<String> formatAndChunkText(
    String text,
    MessageFormatConfig config,
  ) {
    // 如果未启用分段，直接返回原文本
    if (!config.enableChunking) {
      return [text];
    }

    // 处理转义的换行符
    var processedText = text.replaceAll('\\n', '\n');
    // 把连续3个及以上的空格也当作段落分隔符（部分AI用空格代替换行）
    processedText = processedText.replaceAll(RegExp(r' {3,}'), '\n');
    final segments = processedText.split('\n');
    final rawChunks = <String>[];

    for (final segment in segments) {
      if (segment.trim().isEmpty) {
        rawChunks.add('');
        continue;
      }

      rawChunks.addAll(_splitSegment(segment, config));
    }

    // ── 短句合并 ──
    final merged = _mergeShortSentences(rawChunks, config.minSegmentLength);

    // ── 跨段落二次合并 ──
    final finalChunks = _mergeShortSentences(merged, config.minSegmentLength);

    // ── 标点过滤 ──
    if (config.filterPunctuation) {
      return _filterTrailingPunctuation(finalChunks, config);
    }

    return finalChunks.where((chunk) => chunk.trim().isNotEmpty).toList();
  }

  /// 对单个段落（一行文本）执行分段
  static List<String> _splitSegment(String segment, MessageFormatConfig config) {
    // 1) 颜文字保护：提取并替换为占位符
    final kaomojis = KaomojiParser.extractKaomojis(segment);
    const kaomojiPlaceholder = '\x00KMJ';
    var protected = segment;
    for (var i = 0; i < kaomojis.length; i++) {
      protected = protected.replaceFirst(kaomojis[i], '$kaomojiPlaceholder$i\x00');
    }

    // 2) 引号保护：提取并替换为占位符
    final quotedContents = <String>[];
    const quotePlaceholder = '\x00QTE';
    if (config.protectQuotes) {
      for (final m in _quotePattern.allMatches(protected)) {
        quotedContents.add(m.group(0)!);
      }
      for (var i = 0; i < quotedContents.length; i++) {
        protected = protected.replaceFirst(
          quotedContents[i],
          '$quotePlaceholder$i\x00',
        );
      }
    }

    // 3) 按标点分句（带 lookahead：只在标点后面紧跟中英文字符时才切）
    final punctuationPattern =
        config.chunkPunctuations.map((p) => RegExp.escape(p)).join('|');
    // lookbehind: 前面是标点 + lookahead: 后面是中文或英文字母
    final splitPattern =
        RegExp('(?<=[$punctuationPattern])(?=[\u4e00-\u9fffa-zA-Z])');
    final sentences = protected.split(splitPattern);

    // 4) 恢复引号 → 恢复颜文字
    final restored = <String>[];
    for (var sentence in sentences) {
      for (var i = 0; i < quotedContents.length; i++) {
        sentence = sentence.replaceAll('$quotePlaceholder$i\x00', quotedContents[i]);
      }
      for (var i = 0; i < kaomojis.length; i++) {
        sentence = sentence.replaceAll('$kaomojiPlaceholder$i\x00', kaomojis[i]);
      }
      if (sentence.trim().isNotEmpty) {
        restored.add(sentence.trim());
      }
    }

    return restored;
  }

  /// 合并过短的句子
  ///
  /// 规则（参考 astrbot_plugin_smart_segment）：
  /// - 逗号类结尾的短句 → 向后合并（句意未完成）
  /// - 句号类结尾的短句，且前一句是逗号结尾 → 向前合并（补完前句）
  /// - 其他 → 保持独立
  static List<String> _mergeShortSentences(
    List<String> sentences,
    int minLength,
  ) {
    if (sentences.isEmpty) return [];

    final merged = <String>[];
    var pending = ''; // 待向后合并的短句

    for (var sentence in sentences) {
      if (sentence.trim().isEmpty) continue;

      // 有待合并内容，拼到当前句前面
      if (pending.isNotEmpty) {
        sentence = pending + sentence;
        pending = '';
      }

      if (sentence.length <= minLength) {
        if (_endsWithComma(sentence)) {
          // 逗号结尾 → 向后合并
          pending = sentence;
        } else if (_endsWithPeriod(sentence) &&
            merged.isNotEmpty &&
            _endsWithComma(merged.last)) {
          // 句号结尾，前一句是逗号 → 向前合并
          merged.last = merged.last + sentence;
        } else {
          merged.add(sentence);
        }
      } else {
        merged.add(sentence);
      }
    }

    // 处理末尾残留
    if (pending.isNotEmpty) {
      if (merged.isNotEmpty) {
        merged.last = merged.last + pending;
      } else {
        merged.add(pending);
      }
    }

    return merged;
  }

  /// 过滤段末标点（保护颜文字）
  static List<String> _filterTrailingPunctuation(
    List<String> chunks,
    MessageFormatConfig config,
  ) {
    final result = <String>[];
    for (final chunk in chunks) {
      if (chunk.trim().isEmpty) continue;

      // 含颜文字的段不过滤标点
      if (KaomojiParser.containsKaomoji(chunk)) {
        result.add(chunk);
        continue;
      }

      var filtered = chunk;
      for (final punct in config.filterPunctuations) {
        if (filtered.endsWith(punct)) {
          filtered = filtered.substring(0, filtered.length - punct.length);
          break;
        }
      }
      if (filtered.trim().isNotEmpty) {
        result.add(filtered);
      }
    }
    return result;
  }

  static bool _endsWithComma(String s) =>
      s.isNotEmpty && _commaPuncts.contains(s[s.length - 1]);

  static bool _endsWithPeriod(String s) =>
      s.isNotEmpty && _periodPuncts.contains(s[s.length - 1]);
}
