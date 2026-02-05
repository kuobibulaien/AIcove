/// 聊天响应处理器 - 负责处理 AI API 响应的公共逻辑
///
/// 职责：
/// - 处理插件响应（TTS、表情包等）
/// - 构建助手消息（完整存储，分段在 UI 层处理）
/// - 解析后端 TTS 结果
/// - 移除插件标签
///
/// 遵循 DRY 原则：从 ChatActions 中提取的重复代码
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../../core/models/message_block.dart';

/// 助手消息构建结果
class AssistantMessageBuildResult {
  final List<Message> messages;
  final String lastMessageText;

  const AssistantMessageBuildResult({
    required this.messages,
    required this.lastMessageText,
  });
}

/// 助手消息投递结果
class AssistantDeliveryResult {
  final List<Message> messages;
  final String lastMessagePreview;
  final String? placeholderId;

  const AssistantDeliveryResult({
    required this.messages,
    required this.lastMessagePreview,
    this.placeholderId,
  });
}

/// 聊天响应处理器
class ChatResponseHandler {
  const ChatResponseHandler();

  /// 从后端工具结果中解析 TTS 音频消息
  ///
  /// [toolResults] 后端返回的工具调用结果列表
  /// [replyText] AI 回复文本（用于语音气泡显示）
  /// [ttsEnabled] 是否启用 TTS
  Message? parseBackendTtsResult({
    required List<Map<String, dynamic>> toolResults,
    required String replyText,
    required bool ttsEnabled,
  }) {
    if (!ttsEnabled || toolResults.isEmpty) return null;

    try {
      final first = toolResults.firstWhere(
        (e) =>
            (e['name'] ?? '') == 'tts' &&
            ((e['payload'] as Map<String, dynamic>?)?['audio_url']
                    ?.toString()
                    .isNotEmpty ??
                false),
        orElse: () => const {'name': '', 'payload': <String, dynamic>{}},
      );

      if ((first['name'] ?? '') == 'tts') {
        final url =
            ((first['payload'] as Map<String, dynamic>)['audio_url'] as String?)
                ?.trim();
        if (url != null && url.isNotEmpty) {
          final audioId = genId('msg');
          return Message.fromBlocks(
            id: audioId,
            role: 'assistant',
            blocks: [AudioBlock(messageId: audioId, url: url, text: replyText)],
            createdAt: DateTime.now(),
            status: 'sent',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  /// 构建助手消息列表
  ///
  /// 处理表情包事件等，消息保持完整存储，分段在 UI 层处理
  AssistantMessageBuildResult buildAssistantMessages({
    required String replyText,
    required String processedText,
    required List<PluginEvent> pluginEvents,
  }) {
    var sourceText = _selectAssistantText(processedText, pluginEvents, replyText);

    // 如果文本为空但有 trigger 事件，生成确认消息
    if (sourceText.isEmpty) {
      final triggerEvents =
          pluginEvents.where((e) => e.type == 'trigger_created').toList();
      if (triggerEvents.isNotEmpty) {
        final titles = triggerEvents
            .map((e) => e.data['title'] as String?)
            .where((t) => t != null)
            .toList();
        if (titles.isNotEmpty) {
          sourceText = '好的，已设置提醒：${titles.join("、")}';
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
    _appendStickerMessages(aiMessages, pluginEvents);

    return AssistantMessageBuildResult(
      messages: aiMessages,
      lastMessageText: sourceText,
    );
  }

  /// 添加表情包消息
  void _appendStickerMessages(
      List<Message> messages, List<PluginEvent> pluginEvents) {
    final stickerEvents =
        pluginEvents.where((e) => e.type == 'sticker_convert').toList();
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
        messages.add(stickerMsg);
      }
    }
  }

  /// 选择要显示的助手文本
  String _selectAssistantText(
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
  ///
  /// 这是一个公共方法，可以在其他地方复用
  String stripPluginTags(String text) {
    if (text.isEmpty) return text;
    var result = text;

    // 移除 <tts>...</tts> 标签
    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final ttsMatches = ttsRegex
        .allMatches(result)
        .map((m) => m.group(1)?.trim())
        .where((v) => v != null && v.isNotEmpty)
        .toList();
    result = result.replaceAll(ttsRegex, '');

    // 移除 <create_trigger ... /> 标签
    result = result.replaceAll(
        RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false), '');

    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(
        RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false), '');

    result = result.trim();

    // 如果移除标签后为空，但有 TTS 内容，返回 TTS 内容
    if (result.isEmpty && ttsMatches.isNotEmpty) {
      return ttsMatches.cast<String>().join('\n\n');
    }

    return result;
  }

  /// 仅移除 TTS 标签
  String stripTtsTags(String text) {
    if (text.isEmpty) return text;
    final regex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    final matches = regex
        .allMatches(text)
        .map((m) => m.group(1)?.trim())
        .where((value) => value != null && value.isNotEmpty)
        .toList();
    final withoutTags = text.replaceAll(regex, '').trim();
    if (withoutTags.isNotEmpty) {
      return withoutTags;
    }
    if (matches.isNotEmpty) {
      return matches.join('\n\n');
    }
    return '';
  }

  /// 收集 TTS 文本段落
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

  /// 检查是否有 TTS 事件
  bool hasTtsEvents(List<PluginEvent> pluginEvents) {
    return pluginEvents.any((e) => e.type == 'tts_convert');
  }

  /// 检查消息列表中是否包含音频
  bool hasAudioInMessages(List<Message> messages) {
    return messages.any((m) => m.blocks?.any((b) => b is AudioBlock) ?? false);
  }
}

/// 单例实例（无状态，可以共享）
const chatResponseHandler = ChatResponseHandler();
