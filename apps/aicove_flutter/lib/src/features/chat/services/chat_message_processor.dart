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
/// - 2026-02-26: draw_image 图片按占位回插，避免总在首尾
/// - 2026-03-18: 统一图片标签为 <image></image>，快速模式图片改为后补分段
library;

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_content_tags.dart';
import '../../plugins/tts/tts_parser.dart';
import '../../../core/models/message_block.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'chat_types.dart';

/// 多模态片段类型（供 ChatTtsHandler 使用）
enum MultimodalSegmentType { text, tts, sticker, image }

/// 多模态片段（供 ChatTtsHandler 使用）
class MultimodalSegment {
  final MultimodalSegmentType type;
  final String content;

  /// 表情包段携带的事件数据（stickerId, assetPath, tag 等）
  final Map<String, dynamic>? stickerData;

  /// 图片段携带的事件数据（prompt 等）
  final Map<String, dynamic>? imageData;

  const MultimodalSegment({
    required this.type,
    required this.content,
    this.stickerData,
    this.imageData,
  });
}

// ===== 内部类型 =====

enum _SegType { text, tts, sticker, image }

class _Seg {
  final _SegType type;
  final String content;
  final Map<String, dynamic>? data;
  const _Seg(this.type, this.content, {this.data});
}

/// 助手消息处理服务
///
/// 提供消息构建、文本处理等无状态工具方法
/// 注意：普通分段逻辑已移至 UI 层，但多模态标签（TTS、表情包）必须在存储时拆分
class ChatMessageProcessor {
  const ChatMessageProcessor();
  static final RegExp _imagePlaceholderRegex = RegExp(
    r'(?:<image>\s*</image>|\[(?:图片|image)(?:\s*:[^\]]*)?\])',
    caseSensitive: false,
  );
  static final RegExp _punctuationOnlyTextRegex = RegExp(
    r'^[\s\.,!?;:，。！？；：、…·~\-—_()\[\]{}<>《》“”‘’|\\/]+$',
  );

  /// 构建助手消息列表
  ///
  /// 多模态拆分机制：当回复中包含 <tts> 或 [表情包] 标签时，
  /// 按标签在原文中的位置拆分，保证"文字-多媒体-文字"的原始语序。
  /// 这与前端的标点分段（enableChunking）无关，是数据层的必要处理。
  AssistantMessageBuildResult buildAssistantMessages({
    required String replyText,
    required String processedText,
    String? displayReplyText,
    required List<PluginEvent> pluginEvents,
    List<PluginContent>? contents,
    List<ToolAudioResult> toolAudioResults = const [],
    List<ToolCall> toolCalls = const [],
    List<ToolResult> rawToolResults = const [],
  }) {
    final aiMessages = <Message>[];
    final normalizedContents = contents ?? const <PluginContent>[];
    final imageContents = normalizedContents
        .whereType<PluginImageContent>()
        .toList(growable: false);
    final audioContents = normalizedContents
        .whereType<PluginAudioContent>()
        .toList(growable: false);
    final nonImageContents = normalizedContents
        .where((content) =>
            content is! PluginImageContent && content is! PluginAudioContent)
        .toList(growable: false);

    // 1. 先处理非图片内容（文本/音频等）
    if (nonImageContents.isNotEmpty) {
      aiMessages.addAll(_processPluginContents(nonImageContents));
    }

    // 2. 如果非图片内容中没有文本，则从回复文本中构建文本消息
    final hasTextContent = nonImageContents.any((c) => c is PluginTextContent);
    if (!hasTextContent) {
      // 检查是否有多模态事件（TTS 语音或表情包）
      final hasMultimodal = pluginEvents.any(
        (e) =>
            e.type == 'tts_convert' ||
            e.type == 'sticker_convert' ||
            e.type == 'image_generate',
      );

      if (hasMultimodal) {
        // 有多模态标签：按标签位置拆分，保证语序正确
        // TTS 段由 ChatTtsHandler 顺序处理，这里跳过
        final segments = _parseMultimodalSegments(
          displayReplyText ?? replyText, pluginEvents,
        );
        var audioContentIndex = 0;
        var toolAudioIndex = 0;
        var imageContentIndex = 0;
        for (final segment in segments) {
          if (segment.content.trim().isEmpty) continue;

          switch (segment.type) {
            case _SegType.text:
              aiMessages.add(_buildTextMessage(segment.content.trim()));
              break;
            case _SegType.tts:
              if (audioContentIndex < audioContents.length) {
                aiMessages.add(
                  _buildAudioMessageFromPluginContent(
                    audioContents[audioContentIndex],
                    text: segment.content.trim(),
                  ),
                );
                audioContentIndex += 1;
                break;
              }
              if (toolAudioIndex < toolAudioResults.length) {
                aiMessages.add(
                  _buildAudioMessageFromToolAudioResult(
                    toolAudioResults[toolAudioIndex],
                    fallbackText: segment.content.trim(),
                  ),
                );
                toolAudioIndex += 1;
              }
              break;
            case _SegType.sticker:
              final assetPath = segment.data?['assetPath'] as String?;
              final stickerId = segment.data?['stickerId'] as String?;
              final tag = segment.data?['tag'] as String?;
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
              break;
            case _SegType.image:
              if (imageContentIndex < imageContents.length) {
                final image = imageContents[imageContentIndex];
                aiMessages.add(
                  _buildImageMessage(
                    PluginImageContent(
                      image.localPath,
                      caption: image.caption ?? segment.content.trim(),
                      generationSnapshot: image.generationSnapshot,
                    ),
                  ),
                );
                imageContentIndex += 1;
              }
              break;
          }
        }
        if (imageContentIndex < imageContents.length) {
          aiMessages.addAll(
            _processPluginContents(imageContents.skip(imageContentIndex).toList(
              growable: false,
            )),
          );
        }
        if (audioContentIndex < audioContents.length) {
          for (final content in audioContents.skip(audioContentIndex)) {
            aiMessages.add(_buildAudioMessageFromPluginContent(content));
          }
        }
        if (toolAudioIndex < toolAudioResults.length) {
          for (final result in toolAudioResults.skip(toolAudioIndex)) {
            aiMessages.add(_buildAudioMessageFromToolAudioResult(result));
          }
        }
      } else {
        // 无多模态标签：保持消息完整
        var sourceText =
            selectAssistantText(
              processedText, pluginEvents, replyText,
              processedTextProvided: displayReplyText != null,
            );

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
              sourceText = '好的，已设置提醒：${titles.join("、")} ✓';
            }
          }
        }

        if (toolAudioResults.isNotEmpty) {
          for (final result in toolAudioResults) {
            aiMessages.add(_buildAudioMessageFromToolAudioResult(result));
          }
        }
        if (audioContents.isNotEmpty) {
          for (final content in audioContents) {
            aiMessages.add(_buildAudioMessageFromPluginContent(content));
          }
        }

        // draw_image 内容优先按 [图片] 占位插回原文；没有占位时追加到文本后
        if (imageContents.isNotEmpty) {
          aiMessages.addAll(
            _interleaveTextAndImages(sourceText, imageContents),
          );
        } else if (sourceText.isNotEmpty) {
          aiMessages.add(_buildTextMessage(sourceText));
        }
      }
    }

    // 如果存在 PluginTextContent，则图片无法从正文推断插入位点，按顺序追加
    if (hasTextContent && imageContents.isNotEmpty) {
      aiMessages.addAll(_processPluginContents(imageContents));
    }

    // 注意：表情包已在上面的多模态拆分中按位置处理，不再单独追加

    // 附加 ToolBlocks，将 AI 调用的工具和结果记录入库
    if (toolCalls.isNotEmpty) {
      final toolBlocks = <ToolBlock>[];
      for (final call in toolCalls) {
        final result = rawToolResults.firstWhere((r) => r.toolCallId == call.id,
            orElse: () => ToolResult(
                toolCallId: call.id,
                name: call.name,
                result: '{"error": "no result"}'));
        toolBlocks.add(ToolBlock(
          messageId: 'tmp',
          toolCallId: call.id,
          toolName: call.name,
          arguments: call.arguments,
          result: {'content': result.result},
        ));
      }

      if (aiMessages.isNotEmpty) {
        final lastMsg = aiMessages.last;
        final newBlocks = List<MessageBlock>.from(lastMsg.blocks ?? []);
        if (lastMsg.content.isNotEmpty && newBlocks.isEmpty) {
          newBlocks
              .add(TextBlock(messageId: lastMsg.id, content: lastMsg.content));
        }
        for (final tb in toolBlocks) {
          newBlocks.add(ToolBlock(
              messageId: lastMsg.id,
              toolCallId: tb.toolCallId,
              toolName: tb.toolName,
              arguments: tb.arguments,
              result: tb.result));
        }
        aiMessages[aiMessages.length - 1] = lastMsg.copyWith(
          content: '',
          blocks: newBlocks,
        );
      } else {
        final msgId = genId('msg');
        aiMessages.add(Message.fromBlocks(
          id: msgId,
          role: 'assistant',
          blocks: toolBlocks
              .map((b) => ToolBlock(
                  messageId: msgId,
                  toolCallId: b.toolCallId,
                  toolName: b.toolName,
                  arguments: b.arguments,
                  result: b.result))
              .toList(),
          createdAt: DateTime.now(),
          status: 'sent',
        ));
      }
    }

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
                _SegType.image => MultimodalSegmentType.image,
              },
              content: s.content,
              stickerData: s.type == _SegType.sticker ? s.data : null,
              imageData: s.type == _SegType.image ? s.data : null,
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

    // 图片段只对应本轮确认过的 image_generate 事件
    final imageEvents = pluginEvents
        .where((event) => event.type == 'image_generate')
        .toList(growable: false);
    var imageEventIndex = 0;

    final segments = <_Seg>[];
    final pendingText = StringBuffer();

    void addText(String value) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) segments.add(_Seg(_SegType.text, trimmed));
    }

    // 表情包只在标签外的文本里识别；语音、图片正文里的 [tag] 属于其内容
    void flushText() {
      final chunk = pendingText.toString();
      pendingText.clear();
      var cursor = 0;
      for (final match in _stickerTagRegex.allMatches(chunk)) {
        final tag = match.group(1)?.trim() ?? '';
        final data = stickerDataByTag[tag];
        if (data == null) continue;
        addText(chunk.substring(cursor, match.start));
        segments.add(_Seg(_SegType.sticker, tag, data: data));
        cursor = match.end;
      }
      addText(chunk.substring(cursor));
    }

    for (final segment in firstPartyContentTagScanner.scan(cleanedText)) {
      if (TtsParser.isSpeechElement(segment)) {
        final content = (segment as ContentTagElement).inner.trim();
        if (content.isNotEmpty) {
          flushText();
          segments.add(_Seg(_SegType.tts, content));
          continue;
        }
      } else if (_isInlineImageElement(segment) &&
          imageEventIndex < imageEvents.length) {
        final prompt = (segment as ContentTagElement).inner.trim();
        if (prompt.isNotEmpty) {
          flushText();
          segments.add(_Seg(
            _SegType.image,
            prompt,
            data: imageEvents[imageEventIndex].data,
          ));
          imageEventIndex += 1;
          continue;
        }
      }
      pendingText.write(segment.raw);
    }
    flushText();
    return segments;
  }

  static final RegExp _stickerTagRegex = RegExp(r'\[([^\[\]]+)\]');

  static bool _isInlineImageElement(ContentTagSegment segment) =>
      segment is ContentTagElement &&
      segment.closed &&
      ImagePlugin.isInlineImageElement(segment);

  /// 移除非多模态的插件标签（保留 TTS / 图片 / 表情包标签）
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
            messages.add(_buildTextMessage(text));
          }

        case PluginImageContent(:final localPath, :final caption):
          messages.add(
            _buildImageMessage(
              PluginImageContent(localPath, caption: caption, generationSnapshot: content.generationSnapshot),
            ),
          );

        case PluginAudioContent(:final localPath, :final duration):
          final msgId = genId('audio');
          final audioUrl =
              localPath.startsWith('file://') ? localPath : 'file://$localPath';
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

  List<Message> _interleaveTextAndImages(
    String text,
    List<PluginImageContent> images,
  ) {
    final messages = <Message>[];
    if (images.isEmpty) {
      final normalized = text.trim();
      if (normalized.isNotEmpty) {
        messages.add(_buildTextMessage(normalized));
      }
      return messages;
    }

    final normalizedText = text.trim();
    if (normalizedText.isEmpty) {
      for (final image in images) {
        messages.add(_buildImageMessage(image));
      }
      return messages;
    }

    var cursor = 0;
    var imageIndex = 0;
    final matches = _imagePlaceholderRegex.allMatches(normalizedText);
    for (final match in matches) {
      if (imageIndex >= images.length) {
        break;
      }

      if (match.start > cursor) {
        final before = normalizedText.substring(cursor, match.start).trim();
        if (_isMeaningfulImageAdjacentText(before)) {
          messages.add(_buildTextMessage(before));
        }
      }

      messages.add(_buildImageMessage(images[imageIndex]));
      imageIndex += 1;
      cursor = match.end;
    }

    if (cursor < normalizedText.length) {
      final tail = normalizedText.substring(cursor).trim();
      if (_isMeaningfulImageAdjacentText(tail)) {
        messages.add(_buildTextMessage(tail));
      }
    }

    for (; imageIndex < images.length; imageIndex++) {
      messages.add(_buildImageMessage(images[imageIndex]));
    }

    return messages;
  }

  bool _isMeaningfulImageAdjacentText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return false;
    return !_punctuationOnlyTextRegex.hasMatch(normalized);
  }

  Message _buildTextMessage(String text) => Message(
        id: genId('msg'),
        role: 'assistant',
        content: text,
        createdAt: DateTime.now(),
        status: 'sent',
      );

  Message _buildImageMessage(PluginImageContent content) {
    final msgId = genId('img');
    return Message.fromBlocks(
      id: msgId,
      role: 'assistant',
      blocks: [
        ImageBlock(
          messageId: msgId,
          localPath: content.localPath,
          prompt: content.caption,
          generationSnapshot: content.generationSnapshot,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sent',
    );
  }

  Message _buildAudioMessageFromPluginContent(
    PluginAudioContent content, {
    String? text,
  }) {
    final msgId = genId('audio');
    final audioUrl = content.localPath.startsWith('file://')
        ? content.localPath
        : 'file://${content.localPath}';
    return Message.fromBlocks(
      id: msgId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: msgId,
          url: audioUrl,
          text: (text?.trim().isNotEmpty ?? false) ? text!.trim() : null,
          durationSeconds: content.duration?.inSeconds.toDouble(),
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sent',
    );
  }

  Message _buildAudioMessageFromToolAudioResult(
    ToolAudioResult result, {
    String? fallbackText,
  }) {
    final msgId = genId('audio');
    final text = result.text.trim().isNotEmpty
        ? result.text.trim()
        : fallbackText?.trim();
    return Message.fromBlocks(
      id: msgId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: msgId,
          url: result.audioUrl,
          text: text,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sent',
    );
  }

  /// 选择用于显示的助手文本
  String selectAssistantText(
    String processedText,
    List<PluginEvent> pluginEvents,
    String replyText, {
    bool processedTextProvided = false,
  }) {
    final trimmedProcessed = processedText.trim();
    if (processedTextProvided || trimmedProcessed.isNotEmpty) {
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
    final ttsMatches = <String>[];
    final kept = StringBuffer();
    for (final segment in firstPartyContentTagScanner.scan(text)) {
      if (TtsParser.isSpeechElement(segment)) {
        // 移除 <tts>...</tts> 标签，但保留内容（清理 MiniMax 专有标签后）
        final content = (segment as ContentTagElement).inner.trim();
        if (content.isEmpty) continue;
        final spoken = TtsParser.stripMinimaxTags(content);
        if (spoken.isNotEmpty) ttsMatches.add(spoken);
        continue;
      }
      // 只移除快速模式 <image>...</image>，带属性的图片上下文记录原样保留
      if (_isInlineImageElement(segment)) continue;
      kept.write(segment.raw);
    }
    var result = kept.toString();

    // 移除 <create_trigger ... /> 标签
    result = result.replaceAll(
        RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false), '');

    // 移除 <delete_trigger ... /> 标签
    result = result.replaceAll(
        RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false), '');

    result = result.trim();

    // 如果移除标签后为空，但有 TTS 内容，返回 TTS 内容
    if (result.isEmpty && ttsMatches.isNotEmpty) {
      return ttsMatches.join('\n\n');
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
      segments.addAll(
        TtsParser.parse(replyText).segments.map((segment) => segment.text),
      );
    }

    return segments;
  }
}

/// 单例实例
const chatMessageProcessor = ChatMessageProcessor();
