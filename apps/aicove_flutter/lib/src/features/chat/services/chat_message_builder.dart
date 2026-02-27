/// 聊天消息构建器
/// 
/// 负责将 AI 回复文本转换为 Message 对象列表。
/// 
/// 从 chat_actions.dart 提取，遵循单一职责原则。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../../core/models/message_block.dart';

/// 消息构建结果
class AssistantMessageBuildResult {
  final List<Message> messages;
  final String lastMessageText;

  const AssistantMessageBuildResult({
    required this.messages,
    required this.lastMessageText,
  });
}

/// 聊天消息构建器
class ChatMessageBuilder {
  const ChatMessageBuilder();

  /// 构建助手消息列表
  ///
  /// [replyText] - 原始 AI 回复文本
  /// [processedText] - 插件处理后的文本
  /// [pluginEvents] - 插件事件列表
  ///
  /// 注意：消息保持完整存储，分段仅在 UI 层渲染时处理
  AssistantMessageBuildResult buildAssistantMessages({
    required String replyText,
    required String processedText,
    required List<PluginEvent> pluginEvents,
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

    // 消息保持完整存储，不分段
    final aiMessages = <Message>[
      Message(
        id: genId('msg'),
        role: 'assistant',
        content: sourceText,
        createdAt: DateTime.now(),
        status: 'sent',
      ),
    ];

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
      lastMessageText: sourceText,
    );
  }

  /// 选择要显示的助手文本
  String selectAssistantText(
    String processedText,
    List<PluginEvent> pluginEvents,
    String replyText,
  ) {
    final trimmedProcessed = processedText.trim();
    if (trimmedProcessed.isNotEmpty) {
      return trimmedProcessed;
    }

    // 如果检测到 TTS 事件，说明这轮回复应以语音为主，避免渲染文本气泡
    final hasTts = pluginEvents.any((e) => e.type == 'tts_convert');
    if (hasTts) {
      return '';
    }

    // 使用更完整的标签移除函数
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
    result = result.replaceAll(RegExp(r'<create_trigger\s[^>]*?/?>'), '');
    
    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(RegExp(r'<delete_trigger\s[^>]*?/?>'), '');
    
    result = result.trim();
    
    // 如果移除标签后为空，但有 TTS 内容，返回 TTS 内容
    if (result.isEmpty && ttsMatches.isNotEmpty) {
      return ttsMatches.cast<String>().join('\n\n');
    }
    
    return result;
  }

  /// 收集 TTS 文本
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

/// 全局单例
const chatMessageBuilder = ChatMessageBuilder();
