/// 聊天消息处理服务
///
/// 从 chat_actions.dart 提取的消息构建和文本处理逻辑。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
/// - 2026-01-06: 增加多媒体内容处理支持 (PluginContent)
/// - 2026-01-28: 移除分段逻辑，分段改为纯前端展示
/// - 2026-01-28: TTS 标签必须拆分，文本和语音交替出现
/// - 2026-02-21: 统一多模态拆分机制，表情包也按原始位置拆分保证语序
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../plugins/tts/tts_parser.dart';
import '../../../core/models/message_block.dart';
import 'chat_types.dart';

/// 多模态片段类型（供 ChatTtsHandler 使用）
enum MultimodalSegmentType { text, tts, sticker }

/// 多模态片段（供 ChatTtsHandler 使用）
class MultimodalSegment {
  final MultimodalSegmentType type;
  final String content;

  /// 表情包段携带的事件数据（stickerId, assetPath, tag 等）
  final Map<String, dynamic>? stickerData;

  const MultimodalSegment({
    required this.type,
    required this.content,
    this.stickerData,
  });
}

// ===== 内部类型 =====

enum _SegType { text, tts, sticker }

class _Seg {
  final _SegType type;
  final String content;
  final Map<String, dynamic>? stickerData;
  const _Seg(this.type, this.content, {this.stickerData});
}

/// 内部标记位置（用于排序和去重叠）
class _Marker {
  final int start;
  final int end;
  final _SegType type;
  final String content;
  final Map<String, dynamic>? data;
  const _Marker({
    required this.start,
    required this.end,
    required this.type,
    required this.content,
    this.data,
  });
}

/// 助手消息处理服务
///
/// 提供消息构建、文本处理等无状态工具方法
/// 注意：普通分段逻辑已移至 UI 层，但多模态标签（TTS、表情包）必须在存储时拆分
class ChatMessageProcessor {
  const ChatMessageProcessor();

  /// 构建助手消息列表
  ///
  /// 多模态拆分机制：当回复中包含 <tts> 或 [表情包] 标签时，
  /// 按标签在原文中的位置拆分，保证"文字-多媒体-文字"的原始语序。
  /// 这与前端的标点分段（enableChunking）无关，是数据层的必要处理。
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
    final hasTextContent =
        contents?.any((c) => c is PluginTextContent) ?? false;
    if (!hasTextContent) {
      // 检查是否有多模态事件（TTS 语音或表情包）
      final hasMultimodal = pluginEvents.any(
        (e) => e.type == 'tts_convert' || e.type == 'sticker_convert',
      );

      if (hasMultimodal) {
        // 有多模态标签：按标签位置拆分，保证语序正确
        // TTS 段由 ChatTtsHandler 顺序处理，这里跳过
        final segments = _parseMultimodalSegments(replyText, pluginEvents);
        for (final segment in segments) {
          if (segment.content.trim().isEmpty) continue;

          switch (segment.type) {
            case _SegType.text:
              aiMessages.add(Message(
                id: genId('msg'),
                role: 'assistant',
                content: segment.content.trim(),
                createdAt: DateTime.now(),
                status: 'sent',
              ));
            case _SegType.tts:
              // TTS 段不在这里处理，交给 ChatTtsHandler
              break;
            case _SegType.sticker:
              final assetPath =
                  segment.stickerData?['assetPath'] as String?;
              final stickerId =
                  segment.stickerData?['stickerId'] as String?;
              final tag = segment.stickerData?['tag'] as String?;
              if (assetPath != null && assetPath.isNotEmpty) {
                aiMessages.add(Message.fromBlocks(
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
                ));
              }
          }
        }
      } else {
        // 无多模态标签：保持消息完整
        var sourceText =
            selectAssistantText(processedText, pluginEvents, replyText);

        // 如果文本为空但有 trigger 事件，生成确认消息
        if (sourceText.isEmpty) {
          final triggerEvents = pluginEvents
              .where((e) => e.type == 'trigger_created')
              .toList();
          if (triggerEvents.isNotEmpty) {
            final titles = triggerEvents
                .map((e) => e.data['title'] as String?)
                .where((t) => t != null)
                .toList();
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

    // 注意：表情包已在上面的多模态拆分中按位置处理，不再单独追加

    // 计算最后一条消息预览
    final lastMessageText =
        aiMessages.isNotEmpty ? aiMessages.last.displayText : '';

    return AssistantMessageBuildResult(
      messages: aiMessages,
      lastMessageText: lastMessageText,
    );
  }

  /// 解析多模态标签，返回按原文位置排列的片段列表
  ///
  /// 公开此方法供 ChatTtsHandler 使用，用于顺序发送文本、语音和表情包消息
  List<MultimodalSegment> parseMultimodalSegments(
    String text,
    List<PluginEvent> pluginEvents,
  ) {
    final internal = _parseMultimodalSegments(text, pluginEvents);
    return internal
        .map((s) => MultimodalSegment(
              type: switch (s.type) {
                _SegType.text => MultimodalSegmentType.text,
                _SegType.tts => MultimodalSegmentType.tts,
                _SegType.sticker => MultimodalSegmentType.sticker,
              },
              content: s.content,
              stickerData: s.stickerData,
            ))
        .toList();
  }

  /// 解析文本中的多模态标签（<tts> 和 [表情包]），按位置拆分成片段
  ///
  /// 输入: "早安呀~ [早安] <tts>今天天气很好</tts> 出去走走吧"
  /// 输出: [text("早安呀~"), sticker("早安"), tts("今天天气很好"), text("出去走走吧")]
  ///
  /// 注意：
  /// - [tag] 只有匹配到实际表情包事件时才作为 sticker 段
  /// - 嵌套在 <tts> 内部的 [tag] 会被忽略（属于语音内容的一部分）
  List<_Seg> _parseMultimodalSegments(
    String text,
    List<PluginEvent> pluginEvents,
  ) {
    // 先移除非多模态的插件标签（如 trigger），保留 TTS 和 sticker 标签
    final cleanedText = _stripNonTtsTags(text);

    // 收集已匹配的表情包标签
    final stickerDataByTag = <String, Map<String, dynamic>>{};
    for (final event in pluginEvents) {
      if (event.type == 'sticker_convert') {
        final tag = event.data['tag'] as String?;
        if (tag != null) stickerDataByTag[tag] = event.data;
      }
    }

    // 收集所有标记位置
    final markers = <_Marker>[];

    // TTS 标记
    final ttsRegex = RegExp(r'<tts>(.*?)</tts>', dotAll: true);
    for (final match in ttsRegex.allMatches(cleanedText)) {
      final content = match.group(1)?.trim() ?? '';
      if (content.isNotEmpty) {
        markers.add(_Marker(
          start: match.start,
          end: match.end,
          type: _SegType.tts,
          content: content,
        ));
      }
    }

    // 表情包标记（只匹配已确认的表情包标签）
    final stickerRegex = RegExp(r'\[([^\[\]]+)\]');
    for (final match in stickerRegex.allMatches(cleanedText)) {
      final tag = match.group(1)?.trim() ?? '';
      if (stickerDataByTag.containsKey(tag)) {
        markers.add(_Marker(
          start: match.start,
          end: match.end,
          type: _SegType.sticker,
          content: tag,
          data: stickerDataByTag[tag],
        ));
      }
    }

    // 移除被 TTS 标记包含的表情包标记（嵌套场景）
    markers.removeWhere((m) {
      if (m.type != _SegType.sticker) return false;
      return markers.any((other) =>
          other.type == _SegType.tts &&
          m.start >= other.start &&
          m.end <= other.end);
    });

    // 按位置排序
    markers.sort((a, b) => a.start.compareTo(b.start));

    // 按标记位置切分文本
    final segments = <_Seg>[];
    int lastEnd = 0;

    for (final marker in markers) {
      // 标记前的文本
      if (marker.start > lastEnd) {
        final beforeText =
            cleanedText.substring(lastEnd, marker.start).trim();
        if (beforeText.isNotEmpty) {
          segments.add(_Seg(_SegType.text, beforeText));
        }
      }

      // 多模态段
      segments.add(_Seg(
        marker.type,
        marker.content,
        stickerData: marker.data,
      ));

      lastEnd = marker.end;
    }

    // 最后一个标记后的文本
    if (lastEnd < cleanedText.length) {
      final afterText = cleanedText.substring(lastEnd).trim();
      if (afterText.isNotEmpty) {
        segments.add(_Seg(_SegType.text, afterText));
      }
    }

    return segments;
  }

  /// 移除非多模态的插件标签（保留 TTS 和表情包标签）
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
      RegExp(r'<create_trigger\s[^>]*?>.*?</create_trigger>',
          caseSensitive: false, dotAll: true),
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
                prompt: caption,
              ),
            ],
            createdAt: DateTime.now(),
            status: 'sent',
          ));

        case PluginAudioContent(:final localPath, :final duration):
          final msgId = genId('audio');
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
      return TtsParser.stripMinimaxTags(content);
    }).where((v) => v != null && v.isNotEmpty).toList();
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

  /// 收集 TTS 文本片段
  List<String> collectTtsTexts(
      String replyText, List<PluginEvent> pluginEvents) {
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
