import 'kaomoji_parser.dart';

/// 消息格式化配置
class MessageFormatConfig {
  /// 是否启用分段
  final bool enableChunking;

  /// 是否过滤标点
  final bool filterPunctuation;

  /// 分段标点列表
  final List<String> chunkPunctuations;

  /// 过滤标点列表
  final List<String> filterPunctuations;

  /// 表情包发送概率 (0.0 - 1.0，0表示关闭)
  final double stickerProbability;

  const MessageFormatConfig({
    this.enableChunking = false,
    this.filterPunctuation = false,
    this.chunkPunctuations = const ['。', '！', '？', '，', '、', '；', '…'],
    this.filterPunctuations = const ['。', '，', '、', '；', '…', ',', ';'],
    this.stickerProbability = 0.3,
  });

  MessageFormatConfig copyWith({
    bool? enableChunking,
    bool? filterPunctuation,
    List<String>? chunkPunctuations,
    List<String>? filterPunctuations,
    double? stickerProbability,
  }) {
    return MessageFormatConfig(
      enableChunking: enableChunking ?? this.enableChunking,
      filterPunctuation: filterPunctuation ?? this.filterPunctuation,
      chunkPunctuations: chunkPunctuations ?? this.chunkPunctuations,
      filterPunctuations: filterPunctuations ?? this.filterPunctuations,
      stickerProbability: stickerProbability ?? this.stickerProbability,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableChunking': enableChunking,
      'filterPunctuation': filterPunctuation,
      'chunkPunctuations': chunkPunctuations,
      'filterPunctuations': filterPunctuations,
      'stickerProbability': stickerProbability,
    };
  }

  factory MessageFormatConfig.fromJson(Map<String, dynamic> json) {
    return MessageFormatConfig(
      enableChunking: json['enableChunking'] as bool? ?? false,
      filterPunctuation: json['filterPunctuation'] as bool? ?? false,
      chunkPunctuations: (json['chunkPunctuations'] as List<dynamic>?)?.cast<String>() ??
          const ['。', '！', '？', '，', '、', '；', '…'],
      filterPunctuations: (json['filterPunctuations'] as List<dynamic>?)?.cast<String>() ??
          const ['。', '，', '、', '；', '…', ',', ';'],
      stickerProbability: (json['stickerProbability'] as num?)?.toDouble() ?? 0.3,
    );
  }
}

/// 消息格式化器
///
/// 负责消息的格式化处理,包括:
/// - 消息分段和智能分割
/// - 颜文字保护
/// - 标点符号过滤
class MessageFormatter {
  /// 格式化并分段文本
  ///
  /// Args:
  ///   text: 原始文本
  ///   config: 格式化配置
  ///
  /// Returns:
  ///   分段后的文本列表
  static List<String> formatAndChunkText(String text, MessageFormatConfig config) {
    // 如果未启用分段，直接返回原文本
    if (!config.enableChunking) {
      return [text];
    }

    // 处理转义的换行符
    final processedText = text.replaceAll('\\n', '\n');
    final segments = processedText.split('\n');
    final finalChunks = <String>[];

    // 按标点符号分段
    for (final segment in segments) {
      if (segment.trim().isEmpty) {
        finalChunks.add('');
        continue;
      }

      // 使用智能颜文字检测
      final kaomojis = KaomojiParser.extractKaomojis(segment);
      const placeholder = '__KAOMOJI_PLACEHOLDER__';
      var segmentNoKaomoji = segment;

      // 替换颜文字为占位符
      for (var i = 0; i < kaomojis.length; i++) {
        segmentNoKaomoji = segmentNoKaomoji.replaceFirst(
          kaomojis[i],
          '${placeholder}_$i',
        );
      }

      // 构建分段标点的正则表达式
      final punctuationPattern = config.chunkPunctuations
          .map((p) => RegExp.escape(p))
          .join('|');
      final splitPattern = RegExp('(?<=[$punctuationPattern])');

      // 按标点符号分句
      final sentences = segmentNoKaomoji.split(splitPattern);

      // 恢复颜文字
      final restoredSentences = <String>[];
      for (var sentence in sentences) {
        for (var i = 0; i < kaomojis.length; i++) {
          sentence = sentence.replaceAll(
            '${placeholder}_$i',
            kaomojis[i],
          );
        }
        if (sentence.trim().isNotEmpty) {
          restoredSentences.add(sentence.trim());
        }
      }

      finalChunks.addAll(restoredSentences);
    }

    // 智能标点过滤（保护颜文字）
    if (config.filterPunctuation) {
      final processedChunks = <String>[];
      for (final chunk in finalChunks) {
        // 检查是否包含颜文字，如果包含则不过滤标点
        if (KaomojiParser.containsKaomoji(chunk)) {
          processedChunks.add(chunk);
        } else {
          // 检查末尾是否为要过滤的标点
          var filteredChunk = chunk;
          for (final punct in config.filterPunctuations) {
            if (filteredChunk.endsWith(punct)) {
              filteredChunk = filteredChunk.substring(0, filteredChunk.length - punct.length);
              break;
            }
          }
          processedChunks.add(filteredChunk);
        }
      }
      return processedChunks.where((chunk) => chunk.trim().isNotEmpty).toList();
    }

    return finalChunks.where((chunk) => chunk.trim().isNotEmpty).toList();
  }
}
