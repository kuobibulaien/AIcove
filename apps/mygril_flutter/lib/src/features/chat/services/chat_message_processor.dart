/// 聊天消息处理服务
///
/// 从 chat_actions.dart 提取的消息构建和文本处理逻辑。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
/// - 2026-01-06: 增加多媒体内容处理支持 (PluginContent)
/// - 2026-01-28: 移除分段逻辑，分段改为纯前端展示
/// - 2026-01-28: TTS 标签必须拆分，文本和语音交替出现
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../plugins/tts/tts_parser.dart';
import '../../../core/models/message_block.dart';
import 'chat_types.dart';

/// 公开的 TTS 片段类型（供 ChatTtsHandler 使用）
enum TtsSegmentType { text, tts }

/// 公开的 TTS 片段（供 ChatTtsHandler 使用）
class TtsSegment {
  final TtsSegmentType type;
  final String content;
  const TtsSegment({required this.type, required this.content});
}

/// 内部 TTS 内容片段类型
enum _TtsSegmentType { text, tts }

/// 内部 TTS 内容片段
class _TtsSegment {
  final _TtsSegmentType type;
  final String content;
  const _TtsSegment(this.type, this.content);
}

/// 助手消息处理服务
///
/// 提供消息构建、文本处理等无状态工具方法
/// 注意：普通分段逻辑已移至 UI 层，但 TTS 标签必须在存储时拆分
class ChatMessageProcessor {
  const ChatMessageProcessor();

  /// 构建助手消息列表
  ///
  /// [contents] 可选的多媒体内容列表，如果提供则优先处理
  ///
  /// 注意：
  /// - 普通分段已移至 UI 层
  /// - TTS 标签拆分也不在这里处理，由 ChatTtsHandler.sendMessagesWithTts 顺序发送
  /// - 此方法只返回纯文本消息（移除 TTS 标签后的文本）
  AssistantMessageBuildResult buildAssistantMessages({
    required String replyText,
    required String processedText,
    required List<PluginEvent> pluginEvents,
    List<PluginContent>? contents,
  }) {
    final aiMessages = <Message>[];

    // 1. 处理 PluginContent（如果有的话）
    if (contents != null && contents.isNotEmpty) {
      aiMessages.addAll(_processPluginContents(contents));
    }

    // 2. 处理传统文本（如果 contents 中没有文本，或者 contents 为空）
    final hasTextContent = contents?.any((c) => c is PluginTextContent) ?? false;
    if (!hasTextContent) {
      // 检查是否有 TTS 事件（<tts> 标签）
      final hasTts = pluginEvents.any((e) => e.type == 'tts_convert');

      if (hasTts) {
        // 有 TTS 标签：只返回非 TTS 部分的文本
        // TTS 部分由 ChatTtsHandler.sendMessagesWithTts 顺序处理
        final segments = _parseTtsSegments(replyText);
        for (final segment in segments) {
          if (segment.content.trim().isEmpty) continue;

          if (segment.type == _TtsSegmentType.text) {
            // 只添加普通文本消息
            aiMessages.add(Message(
              id: genId('msg'),
              role: 'assistant',
              content: segment.content.trim(),
              createdAt: DateTime.now(),
              status: 'sent',
            ));
          }
          // TTS 段不在这里处理，交给 ChatTtsHandler
        }
      } else {
        // 无 TTS 标签：保持消息完整
        var sourceText = selectAssistantText(processedText, pluginEvents, replyText);

        // 如果文本为空但有 trigger 事件，生成确认消息
        if (sourceText.isEmpty) {
          final triggerEvents = pluginEvents.where((e) => e.type == 'trigger_created').toList();
          if (triggerEvents.isNotEmpty) {
            final titles = triggerEvents.map((e) => e.data['title'] as String?).where((t) => t != null).toList();
            if (titles.isNotEmpty) {
              sourceText = '好的，已设置提醒：${titles.join("、")} ✓';
            }
          }
        }

        // 保持消息完整，不分段
        if (sourceText.isNotEmpty) {
          aiMessages.add(Message(
            id: genId('msg'),
            role: 'assistant',
            content: sourceText,
            createdAt: DateTime.now(),
            status: 'sent',
          ));
        }
      }
    }

    // 3. 处理表情包事件
    final stickerEvents = pluginEvents.where((e) => e.type == 'sticker_convert').toList();
    for (final event in stickerEvents) {
      final stickerId = event.data['stickerId'] as String?;
      final assetPath = event.data['assetPath'] as String?;
      final tag = event.data['tag'] as String?;

      if (assetPath != null && assetPath.isNotEmpty) {
        final stickerMsg = Message.fromBlocks(
          id: genId('sticker'),
          role: 'assistant',
          blocks: [
            EmojiBlock(
              messageId: genId('emoji'),
              emojiId: stickerId ?? tag ?? 'unknown',
              path: assetPath,
              matchedTag: tag,
            ),
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        );
        aiMessages.add(stickerMsg);
      }
    }

    // 计算最后一条消息预览
    final lastMessageText = aiMessages.isNotEmpty
        ? aiMessages.last.displayText
        : '';

    return AssistantMessageBuildResult(
      messages: aiMessages,
      lastMessageText: lastMessageText,
    );
  }

  /// 解析 TTS 标签，返回按顺序排列的片段列表
  ///
  /// 公开此方法供 ChatTtsHandler 使用，用于顺序发送文本和语音消息
  List<TtsSegment> parseTtsSegments(String text) {
    final internal = _parseTtsSegments(text);
    return internal.map((s) => TtsSegment(
      type: s.type == _TtsSegmentType.text ? TtsSegmentType.text : TtsSegmentType.tts,
      content: s.content,
    )).toList();
  }

  /// 解析文本中的 TTS 标签，按位置拆分成片段
  ///
  /// 输入: "你好！<tts>今天天气很好</tts>，我们去公园吧？<tts>走吧</tts>"
  /// 输出: [text("你好！"), tts("今天天气很好"), text("，我们去公园吧？"), tts("走吧")]
  ///
  /// 注意：此方法只处理 <tts> 标签的拆分，不做任何 trim 操作，
  /// 避免丢失标点符号或空格。最终判空在调用处进行。
  List<_TtsSegment> _parseTtsSegments(String text) {
    final segments = <_TtsSegment>[];

    // 先移除非 TTS 的插件标签（如 trigger），但保留其他所有文本
    final cleanedText = _stripNonTtsTags(text);

    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    int lastEnd = 0;

    for (final match in ttsRegex.allMatches(cleanedText)) {
      // 添加 TTS 标签前的文本（保持原样，不 trim）
      if (match.start > lastEnd) {
        final beforeText = cleanedText.substring(lastEnd, match.start);
        // 只有在内容非空白时才添加
        if (beforeText.trim().isNotEmpty) {
          segments.add(_TtsSegment(_TtsSegmentType.text, beforeText.trim()));
        }
      }

      // 添加 TTS 内容
      final ttsContent = match.group(1);
      if (ttsContent != null && ttsContent.trim().isNotEmpty) {
        segments.add(_TtsSegment(_TtsSegmentType.tts, ttsContent.trim()));
      }

      lastEnd = match.end;
    }

    // 添加最后一个 TTS 标签后的文本
    if (lastEnd < cleanedText.length) {
      final afterText = cleanedText.substring(lastEnd);
      if (afterText.trim().isNotEmpty) {
        segments.add(_TtsSegment(_TtsSegmentType.text, afterText.trim()));
      }
    }

    return segments;
  }

  /// 移除非 TTS 的插件标签（保留其他所有文本）
  ///
  /// 只移除标签本身，不改动其他任何字符（包括空格、标点）
  String _stripNonTtsTags(String text) {
    var result = text;
    // 移除 <create_trigger ... /> 或 <create_trigger ...></create_trigger> 标签
    result = result.replaceAll(
      RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(r'<create_trigger\s[^>]*?>.*?</create_trigger>', caseSensitive: false, dotAll: true),
      '',
    );
    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(
      RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false),
      '',
    );
    // 注意：不做 trim，保留原始文本格式
    return result;
  }
  
  /// 处理 PluginContent 列表，将其转换为 Message 列表
  List<Message> _processPluginContents(List<PluginContent> contents) {
    final messages = <Message>[];
    
    for (final content in contents) {
      switch (content) {
        case PluginTextContent(:final text):
          if (text.isNotEmpty) {
            messages.add(Message(
              id: genId('msg'),
              role: 'assistant',
              content: text,
              createdAt: DateTime.now(),
              status: 'sent',
            ));
          }
          
        case PluginImageContent(:final localPath, :final caption):
          final msgId = genId('img');
          messages.add(Message.fromBlocks(
            id: msgId,
            role: 'assistant',
            blocks: [
              ImageBlock(
                messageId: msgId,
                localPath: localPath,
                prompt: caption, // 使用 prompt 字段存储说明文字
              ),
            ],
            createdAt: DateTime.now(),
            status: 'sent',
          ));
          
        case PluginAudioContent(:final localPath, :final duration):
          final msgId = genId('audio');
          // AudioBlock 需要 url，对于本地文件需要转换为 file:// 格式
          final audioUrl = localPath.startsWith('file://') 
              ? localPath 
              : 'file://$localPath';
          messages.add(Message.fromBlocks(
            id: msgId,
            role: 'assistant',
            blocks: [
              AudioBlock(
                messageId: msgId,
                url: audioUrl,
                durationSeconds: duration?.inSeconds.toDouble(),
              ),
            ],
            createdAt: DateTime.now(),
            status: 'sent',
          ));
          
        case PluginWidgetContent():
          // Widget 内容暂不支持持久化，可以考虑生成占位消息
          // 或者在 UI 层特殊处理（需要进一步设计）
          break;
      }
    }
    
    return messages;
  }

  /// 选择用于显示的助手文本
  String selectAssistantText(
    String processedText,
    List<PluginEvent> pluginEvents,
    String replyText,
  ) {
    final trimmedProcessed = processedText.trim();
    if (trimmedProcessed.isNotEmpty) {
      return trimmedProcessed;
    }

    // 如果检测到 TTS 事件，说明这轮回复应以语音为主
    final hasTts = pluginEvents.any((e) => e.type == 'tts_convert');
    if (hasTts) {
      return '';
    }

    return stripPluginTags(replyText);
  }

  /// 移除所有插件标签（TTS、Trigger 等）
  ///
  /// 对于 TTS 标签内的内容，还会清理 MiniMax 专有标签（语气词、停顿控制）
  String stripPluginTags(String text) {
    if (text.isEmpty) return text;
    var result = text;

    // 移除 <tts>...</tts> 标签，但保留内容（清理 MiniMax 专有标签后）
    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final ttsMatches = ttsRegex.allMatches(result).map((m) {
      final content = m.group(1)?.trim();
      if (content == null || content.isEmpty) return null;
      // 清理 TTS 内容中的 MiniMax 标签（语气词、停顿等）
      return TtsParser.stripMinimaxTags(content);
    }).where((v) => v != null && v.isNotEmpty).toList();
    result = result.replaceAll(ttsRegex, '');

    // 移除 <create_trigger ... /> 标签
    result = result.replaceAll(RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false), '');

    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false), '');

    result = result.trim();

    // 如果移除标签后为空，但有 TTS 内容，返回 TTS 内容
    if (result.isEmpty && ttsMatches.isNotEmpty) {
      return ttsMatches.cast<String>().join('\n\n');
    }

    return result;
  }

  /// 收集 TTS 文本片段
  List<String> collectTtsTexts(String replyText, List<PluginEvent> pluginEvents) {
    final segments = <String>[];
    for (final event in pluginEvents) {
      if (event.type != 'tts_convert') continue;
      final original = (event.data['originalText'] as String?)?.trim();
      final fallback = (event.data['text'] as String?)?.trim();
      final text = original?.isNotEmpty == true ? original : fallback;
      if (text != null && text.isNotEmpty) {
        segments.add(text);
      }
    }

    if (segments.isEmpty) {
      final regex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
      for (final match in regex.allMatches(replyText)) {
        final value = match.group(1)?.trim();
        if (value != null && value.isNotEmpty) {
          segments.add(value);
        }
      }
    }

    return segments;
  }
}

/// 单例实例
const chatMessageProcessor = ChatMessageProcessor();
