import 'package:mygril_flutter/src/core/models/message_block.dart';
import '../domain/emoji_model.dart';
import 'emoji_matcher.dart';
import 'emoji_manager.dart';

/// 表情包段落
class EmojiSegment {
  /// 文本内容
  final String text;

  /// 是否是表情包
  final bool isEmoji;

  /// 匹配的表情包（如果是表情包）
  final EmojiModel? emoji;

  /// 原始标签文本
  final String? originalTag;

  const EmojiSegment({
    required this.text,
    required this.isEmoji,
    this.emoji,
    this.originalTag,
  });
}

/// 表情包解析器
/// 负责解析 <emo> 标签并转换为 MessageBlock
class EmojiParser {
  final EmojiManager _manager;
  final EmojiMatcher _matcher;

  EmojiParser(this._manager, this._matcher);

  /// 解析文本中的 <emo> 标签
  /// 
  /// 支持的格式：
  /// 1. <emo>抱抱</emo>
  /// 2. <emo tag="抱抱">抱抱宝宝</emo> (优先使用 tag 属性)
  /// 
  /// 返回分段列表，每段包含文本或表情包信息
  List<EmojiSegment> parseEmoTags(String text) {
    final segments = <EmojiSegment>[];

    // 正则匹配 <emo> 标记
    final pattern = RegExp(
      r'<emo(?:\s+tag="([^"]*)")?>(.*?)</emo>',
      dotAll: true,
    );

    var lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      // 添加标记前的文本（普通文本）
      if (match.start > lastEnd) {
        final plainText = text.substring(lastEnd, match.start).trim();
        if (plainText.isNotEmpty) {
          segments.add(EmojiSegment(
            text: plainText,
            isEmoji: false,
          ));
        }
      }

      // 提取标签：优先使用 tag 属性，否则使用内容
      final tagAttr = match.group(1); // tag 属性
      final content = match.group(2)?.trim() ?? ''; // 标签内容
      final tag = tagAttr ?? content;

      // 匹配表情包
      final emoji = _matcher.match(tag);

      if (emoji != null) {
        // 找到匹配的表情包
        segments.add(EmojiSegment(
          text: content,
          isEmoji: true,
          emoji: emoji,
          originalTag: tag,
        ));

        // 增加使用次数
        _manager.incrementUsage(emoji.id);
      } else {
        // 未找到匹配，保留原文本
        segments.add(EmojiSegment(
          text: content.isNotEmpty ? content : tag,
          isEmoji: false,
        ));
      }

      lastEnd = match.end;
    }

    // 添加最后剩余的文本
    if (lastEnd < text.length) {
      final remaining = text.substring(lastEnd).trim();
      if (remaining.isNotEmpty) {
        segments.add(EmojiSegment(
          text: remaining,
          isEmoji: false,
        ));
      }
    }

    // 如果没有找到任何标记，返回整个文本
    if (segments.isEmpty) {
      segments.add(EmojiSegment(
        text: text.trim(),
        isEmoji: false,
      ));
    }

    return segments;
  }

  /// 将分段转换为 MessageBlock 列表
  /// 
  /// 文本段 -> TextBlock
  /// 表情包段 -> EmojiBlock
  List<MessageBlock> segmentsToBlocks(
    String messageId,
    List<EmojiSegment> segments,
  ) {
    final blocks = <MessageBlock>[];

    for (final segment in segments) {
      if (segment.isEmoji && segment.emoji != null) {
        // 创建 EmojiBlock
        blocks.add(EmojiBlock(
          messageId: messageId,
          emojiId: segment.emoji!.id,
          path: segment.emoji!.localPath ?? '',
          matchedTag: segment.originalTag,
          originalText: segment.text,
        ));
      } else {
        // 创建 TextBlock
        if (segment.text.isNotEmpty) {
          blocks.add(TextBlock(
            messageId: messageId,
            content: segment.text,
          ));
        }
      }
    }

    return blocks;
  }

  /// 移除所有 <emo> 标记，返回纯文本
  /// 用于向后兼容或降级显示
  String removeEmoTags(String text) {
    // 移除 <emo> 标记，保留内容
    final pattern = RegExp(
      r'<emo(?:\s+[^>]*)?>(.*?)</emo>',
      dotAll: true,
    );
    final cleanText = text.replaceAllMapped(pattern, (match) {
      return match.group(1) ?? '';
    });
    return cleanText.trim();
  }

  /// 解析消息文本并生成 Block 列表（一步到位）
  /// 
  /// 这是推荐的使用方式
  List<MessageBlock> parseMessageText(String messageId, String text) {
    // 1. 解析标签
    final segments = parseEmoTags(text);

    // 2. 转换为 Blocks
    final blocks = segmentsToBlocks(messageId, segments);

    return blocks;
  }

  /// 检查文本是否包含 <emo> 标签
  bool containsEmoTags(String text) {
    return text.contains(RegExp(r'<emo(?:\s+[^>]*)?>.*?</emo>', dotAll: true));
  }

  /// 统计文本中的表情包数量
  int countEmoTags(String text) {
    final pattern = RegExp(r'<emo(?:\s+[^>]*)?>.*?</emo>', dotAll: true);
    return pattern.allMatches(text).length;
  }

  /// 提取所有表情包标签（用于预加载）
  List<String> extractAllTags(String text) {
    final tags = <String>[];
    final pattern = RegExp(
      r'<emo(?:\s+tag="([^"]*)")?>(.*?)</emo>',
      dotAll: true,
    );

    for (final match in pattern.allMatches(text)) {
      final tagAttr = match.group(1);
      final content = match.group(2)?.trim() ?? '';
      final tag = tagAttr ?? content;
      if (tag.isNotEmpty) {
        tags.add(tag);
      }
    }

    return tags;
  }
}
