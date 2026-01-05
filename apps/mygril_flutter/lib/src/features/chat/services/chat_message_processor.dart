/// 聊天消息处理服务
/// 
/// 从 chat_actions.dart 提取的消息构建和文本处理逻辑。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../../core/models/message_block.dart';
import '../../../core/utils/message_formatter.dart';
import 'chat_types.dart';

/// 助手消息处理服务
/// 
/// 提供消息构建、文本处理等无状态工具方法
class ChatMessageProcessor {
  const ChatMessageProcessor();

  /// 构建助手消息列表
  AssistantMessageBuildResult buildAssistantMessages({
    required String replyText,
    required String processedText,
    required List<PluginEvent> pluginEvents,
    required MessageFormatConfig messageConfig,
  }) {
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
    
    if (sourceText.isEmpty) {
      return const AssistantMessageBuildResult(messages: [], lastMessageText: '');
    }

    final chunks = MessageFormatter.formatAndChunkText(sourceText, messageConfig);
    final texts = chunks.isEmpty ? [sourceText] : chunks;
    final aiMessages = texts
        .map((chunk) => Message(
              id: genId('msg'),
              role: 'assistant',
              content: chunk,
              createdAt: DateTime.now(),
              status: 'sent',
            ))
        .toList();

    // 处理表情包事件
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

    return AssistantMessageBuildResult(
      messages: aiMessages,
      lastMessageText: texts.last,
    );
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
  String stripPluginTags(String text) {
    if (text.isEmpty) return text;
    var result = text;
    
    // 移除 <tts>...</tts> 标签
    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final ttsMatches = ttsRegex.allMatches(result).map((m) => m.group(1)?.trim()).where((v) => v != null && v.isNotEmpty).toList();
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
