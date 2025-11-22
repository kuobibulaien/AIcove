/// TTS 文本解析器
/// 负责解析 <tts></tts> 标记和文本拆分
class TtsParser {
  /// 解析文本中的 TTS 标记
  /// 返回标记列表和移除标记后的纯文本
  static TtsParseResult parse(String text) {
    final matches = RegExp(r'<tts>(.*?)</tts>', dotAll: true).allMatches(text);

    final segments = <TtsSegment>[];
    for (final match in matches) {
      final content = match.group(1)?.trim() ?? '';
      if (content.isNotEmpty) {
        segments.add(TtsSegment(
          text: content,
          startIndex: match.start,
          endIndex: match.end,
        ));
      }
    }

    // 移除所有 TTS 标记
    final cleanText = text.replaceAll(RegExp(r'<tts>.*?</tts>', dotAll: true), '').trim();

    return TtsParseResult(
      segments: segments,
      cleanText: cleanText,
      originalText: text,
    );
  }

  /// 拆分文本（如果超过最大字数限制）
  /// 尽量按句子边界拆分，保持语义完整
  static List<String> splitText(String text, int maxChars) {
    if (text.length <= maxChars) {
      return [text];
    }

    final chunks = <String>[];
    final sentences = _splitBySentenceBoundary(text);

    String currentChunk = '';
    for (final sentence in sentences) {
      if (sentence.length > maxChars) {
        // 单个句子就超过限制，强制按字数拆分
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk);
          currentChunk = '';
        }
        chunks.addAll(_forceSplit(sentence, maxChars));
      } else if (currentChunk.length + sentence.length <= maxChars) {
        // 可以添加到当前块
        currentChunk += sentence;
      } else {
        // 添加会超过限制，保存当前块并开始新块
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk);
        }
        currentChunk = sentence;
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }

    return chunks;
  }

  /// 按句子边界拆分文本
  static List<String> _splitBySentenceBoundary(String text) {
    // 中文句子边界：。！？；
    // 英文句子边界：. ! ? ;
    final pattern = RegExp(r'[。！？；.!?;]+');
    final sentences = <String>[];

    int lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      final sentence = text.substring(lastEnd, match.end).trim();
      if (sentence.isNotEmpty) {
        sentences.add(sentence);
      }
      lastEnd = match.end;
    }

    // 添加剩余部分
    if (lastEnd < text.length) {
      final remaining = text.substring(lastEnd).trim();
      if (remaining.isNotEmpty) {
        sentences.add(remaining);
      }
    }

    return sentences;
  }

  /// 强制按字数拆分（不考虑边界）
  static List<String> _forceSplit(String text, int maxChars) {
    final chunks = <String>[];
    for (int i = 0; i < text.length; i += maxChars) {
      final end = (i + maxChars < text.length) ? i + maxChars : text.length;
      chunks.add(text.substring(i, end));
    }
    return chunks;
  }
}

/// TTS 解析结果
class TtsParseResult {
  /// 解析出的 TTS 文本段
  final List<TtsSegment> segments;

  /// 移除 TTS 标记后的纯文本
  final String cleanText;

  /// 原始文本
  final String originalText;

  TtsParseResult({
    required this.segments,
    required this.cleanText,
    required this.originalText,
  });

  bool get hasTtsContent => segments.isNotEmpty;
}

/// TTS 文本段
class TtsSegment {
  /// 需要转换为语音的文本
  final String text;

  /// 在原文中的起始位置
  final int startIndex;

  /// 在原文中的结束位置
  final int endIndex;

  TtsSegment({
    required this.text,
    required this.startIndex,
    required this.endIndex,
  });

  @override
  String toString() {
    return 'TtsSegment(text: "$text", start: $startIndex, end: $endIndex)';
  }
}
