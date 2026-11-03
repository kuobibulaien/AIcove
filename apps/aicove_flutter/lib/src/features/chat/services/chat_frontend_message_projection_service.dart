library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import '../../../core/api/providers/provider_adapter.dart' show ToolCall;
import '../../plugins/plugin_content_tags.dart';
import '../../stickers/sticker_tag.dart';
import '../../stickers/sticker_library.dart';
import '../domain/message.dart';
import 'chat_message_processor.dart';
import 'chat_message_projection_codec.dart';
import 'chat_types.dart' show ReplyRound;

class ChatFrontendMessageProjectionService {
  const ChatFrontendMessageProjectionService();

  List<Message> projectMessages(Iterable<Message> rawMessages) {
    final projected = <Message>[];
    for (final rawMessage in rawMessages) {
      projected.addAll(projectMessage(rawMessage));
    }
    return projected;
  }

  List<Message> projectMessage(Message rawMessage) {
    final normalized = ChatMessageProjectionCodec.normalizeLegacyMediaPayload(
      rawMessageId: rawMessage.id,
      role: rawMessage.role,
      payload: rawMessage.rawPayload,
      blocks: [for (final block in rawMessage.blocks ?? const <MessageBlock>[]) block.toJson()],
    );
    if (!identical(normalized, rawMessage.rawPayload)) {
      rawMessage = rawMessage.copyWith(rawPayload: normalized);
    }
    final payload = rawMessage.rawPayload;
    if (rawMessage.role != 'assistant' ||
        !ChatMessageProjectionCodec.hasProjectionSemantics(payload)) {
      final cachedProjected = ChatMessageProjectionCodec.projectedMessages(
        payload,
      );
      if (cachedProjected.isNotEmpty) {
        return _normalizeProjectionFromRawMessage(
          rawMessage,
          _dedupeProjectedMessages([
            for (final message in cachedProjected)
              if (_stripCachedStickerMarkup(message) case final visible?)
                visible,
          ]),
          preserveStoredIds: true,
        );
      }
    }

    if (rawMessage.role != 'assistant') {
      final mixedProjection = _projectMixedImageMessage(rawMessage);
      if (mixedProjection.isNotEmpty) {
        return _normalizeProjectionFromRawMessage(rawMessage, mixedProjection);
      }
      return <Message>[_projectPassthroughMessage(rawMessage)];
    }

    if (payload != null) {
      final supplementInsertOps =
          ChatMessageProjectionCodec.supplementInsertOps(payload);
      if (supplementInsertOps.isNotEmpty) {
        final rebuiltBase = const ChatMessageProcessor().buildAssistantMessages(
          rawMessageId: rawMessage.id,
          rawCreatedAt: rawMessage.createdAt,
          replyText:
              ChatMessageProjectionCodec.rawReplyText(payload) ??
              rawMessage.content,
          processedText:
              ChatMessageProjectionCodec.processedText(payload) ?? '',
          displayReplyText: ChatMessageProjectionCodec.displayReplyText(
            payload,
          ),
          pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
          contents: const [],
          toolAudioResults: const [],
          toolCalls: _displayToolCalls(payload),
          rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
          reasoning: ChatMessageProjectionCodec.reasoning(payload),
          // 图片、语音由补插记录放回原位，轮次里不再带。
          replyRounds: [
            for (final round in ChatMessageProjectionCodec.replyRounds(payload))
              ReplyRound(
                replyText: round.replyText,
                rawText: round.rawText,
                processedText: round.processedText,
                pluginEvents: round.pluginEvents,
                reasoning: round.reasoning,
                toolCallIds: round.toolCallIds,
              ),
          ],
        );
        final rebuilt = _applyStoredSupplementInsertOps(
          rebuiltBase.messages,
          supplementInsertOps,
          rawMessage,
        );
        if (rebuilt.isNotEmpty) {
          return _normalizeProjectionFromRawMessage(rawMessage, rebuilt, preserveStoredIds: true);
        }
      }
      final rebuilt = const ChatMessageProcessor().buildAssistantMessages(
        rawMessageId: rawMessage.id,
        rawCreatedAt: rawMessage.createdAt,
        replyText:
            ChatMessageProjectionCodec.rawReplyText(payload) ??
            rawMessage.content,
        processedText: ChatMessageProjectionCodec.processedText(payload) ?? '',
        displayReplyText: ChatMessageProjectionCodec.displayReplyText(payload),
        pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
        contents: ChatMessageProjectionCodec.pluginContents(payload),
        toolAudioResults: ChatMessageProjectionCodec.toolAudioResults(payload),
        toolCalls: _displayToolCalls(payload),
        rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
        reasoning: ChatMessageProjectionCodec.reasoning(payload),
        replyRounds: ChatMessageProjectionCodec.replyRounds(payload),
      );
      if (rebuilt.messages.isNotEmpty) {
        return _normalizeProjectionFromRawMessage(rawMessage, rebuilt.messages);
      }
    }

    if (ChatMessageProjectionCodec.displayReplyText(payload) != null) {
      return const <Message>[];
    }
    final mixedProjection = _projectMixedImageMessage(rawMessage);
    if (mixedProjection.isNotEmpty) {
      return _normalizeProjectionFromRawMessage(rawMessage, mixedProjection);
    }

    return <Message>[_projectPassthroughMessage(rawMessage)];
  }

  List<ToolCall> _displayToolCalls(Map<String, dynamic>? payload) {
    final calls = ChatMessageProjectionCodec.toolCalls(payload);
    // Progress raw records intent before execution. Only settled steps become
    // history cards; unfinished intent remains available for safe model replay.
    if (payload?['stopReason'] != 'inProgress' &&
        payload?['runStatus'] != 'cancelled' &&
        payload?['runStatus'] != 'failed')
      return calls;
    final settled = {
      for (final result in ChatMessageProjectionCodec.rawToolResults(payload))
        result.toolCallId,
    };
    return [
      for (final call in calls)
        if (settled.contains(call.id)) call,
    ];
  }

  Message _projectPassthroughMessage(Message message) {
    final sourceBlocks = message.blocks;
    List<MessageBlock>? blocks = sourceBlocks;
    var content = message.content;
    if (sourceBlocks != null && sourceBlocks.isNotEmpty) {
      var downgraded = false;
      final nextBlocks = <MessageBlock>[];
      for (final block in sourceBlocks) {
        if (message.status != 'sending' &&
            block is AudioBlock &&
            block.url.trim().isEmpty &&
            (block.text?.trim().isNotEmpty ?? false)) {
          downgraded = true;
          nextBlocks.add(
            TextBlock(
              id: block.id,
              messageId: message.id,
              content: block.text!.trim(),
              status: BlockStatus.success,
              createdAt: block.createdAt,
            ),
          );
        } else {
          nextBlocks.add(_resolveStickerBlock(block));
        }
      }
      blocks = nextBlocks;
      if (downgraded) {
        if (content.trim().isEmpty && nextBlocks.length == 1) {
          content = (nextBlocks.single as TextBlock).content;
        }
      }
    }
    return message.copyWith(
      // DB sourceMessageId 是导入来源；展示操作必须指向当前 raw 行。
      sourceMessageId: message.id,
      content: content,
      blocks: blocks,
      rawPayload: message.role == 'assistant'
          ? {
              if (message.rawPayload?['runStatus'] != null)
                'runStatus': message.rawPayload!['runStatus'],
              if (message.rawPayload?['stopReason'] != null)
                'stopReason': message.rawPayload!['stopReason'],
            }
          : null,
    );
  }

  // 旧流式投影可能已经缓存了标签：只清显示副本，不回写 raw 或重放表情事件。
  Message? _stripCachedStickerMarkup(Message message) {
    if (message.role != 'assistant') return message;
    String clean(String text) =>
        StickerTag.removeFrom(firstPartyContentTagScanner, text);
    final content = clean(message.content);
    var changed = content != message.content;
    final blocks = <MessageBlock>[];
    for (final block in message.blocks ?? const <MessageBlock>[]) {
      // 结构化记录也继承 TextBlock，不用普通文本副本替换它们。
      if (block.runtimeType == TextBlock) {
        final text = block as TextBlock;
        final visible = clean(text.content);
        if (visible != text.content) {
          changed = true;
          if (visible.trim().isNotEmpty) {
            blocks.add(text.copyWith(content: visible));
          }
          continue;
        }
      }
      blocks.add(block);
    }
    if (!changed) return message;
    if (content.trim().isEmpty && blocks.isEmpty) return null;
    return message.copyWith(content: content, blocks: blocks);
  }

  List<Message> _normalizeProjectionFromRawMessage(
    Message rawMessage,
    List<Message> messages, {
    bool preserveStoredIds = false,
  }) {
    final normalized = <Message>[
      for (final (index, message) in messages.indexed)
        _normalizeProjectedMessage(
          rawMessage,
          message,
          index,
          preserveStoredIds: preserveStoredIds,
        ),
    ];
    return ChatMessageProjectionCodec.applyRunStatus(
      normalized,
      rawMessage.rawPayload,
    );
  }

  Message _normalizeProjectedMessage(
    Message raw,
    Message projected,
    int index, {
    bool preserveStoredIds = false,
  }) {
    final id = preserveStoredIds || projected.id.startsWith('${raw.id}__proj_')
        ? projected.id
        : '${raw.id}__proj_r0_s${index}_${projected.blocks?.firstOrNull?.type.name ?? 'text'}';
    return projected.copyWith(
      id: id,
      sourceMessageId: raw.id,
      createdAt: raw.createdAt,
      rawPayload: null,
      blocks: projected.blocks == null
          ? null
          : [
              for (final (blockIndex, block) in projected.blocks!.indexed)
                MessageBlock.fromJson({
                  ..._resolveStickerBlock(block).toJson(),
                  'id': preserveStoredIds
                      ? block.id
                      : '${id}__b${blockIndex}_${block.type.name}',
                  'messageId': id,
                  'createdAt': raw.createdAt.toIso8601String(),
                }),
            ],
    );
  }

  MessageBlock _resolveStickerBlock(MessageBlock block) {
    if (block is! EmojiBlock) return block;
    final path = StickerLibrary.resolveLocalPath(block.path, stickerId: block.emojiId);
    if (path == block.path) return block;
    return EmojiBlock.fromJson({...block.toJson(), 'path': path});
  }

  List<Message> _dedupeProjectedMessages(List<Message> messages) {
    final seen = <String>{};
    final result = <Message>[];
    for (final message in messages) {
      final key = _projectedMessageSemanticKey(message);
      if (!seen.add(key)) {
        continue;
      }
      result.add(message);
    }
    return result;
  }

  String _projectedMessageSemanticKey(Message message) {
    return jsonEncode(<String, Object?>{
      'sourceMessageId': message.sourceMessageId?.trim(),
      'role': message.role,
      'content': message.content,
      'blocks': <Map<String, dynamic>>[
        for (final block in message.blocks ?? const <MessageBlock>[])
          (block.toJson()
            ..remove('id')
            ..remove('messageId')
            ..remove('createdAt')),
      ],
    });
  }

  List<Message> _projectMixedImageMessage(Message rawMessage) {
    final blocks = rawMessage.blocks;
    if (blocks == null || blocks.isEmpty) {
      return const <Message>[];
    }

    final textBlocks = <TextBlock>[];
    final imageBlocks = <ImageBlock>[];
    for (final block in blocks) {
      if (block is TextBlock) {
        if (block.content.trim().isNotEmpty) {
          textBlocks.add(block);
        }
        continue;
      }
      if (block is ImageBlock) {
        imageBlocks.add(block);
        continue;
      }
      return const <Message>[];
    }

    if (textBlocks.isEmpty || imageBlocks.isEmpty) {
      return const <Message>[];
    }

    final textContent = textBlocks
        .map((block) => block.content.trim())
        .join('\n\n');
    if (textContent.isEmpty) {
      return const <Message>[];
    }

    final projected = <Message>[
      Message(
        id: '${rawMessage.id}__proj_00_text',
        role: rawMessage.role,
        content: textContent,
        createdAt: rawMessage.createdAt,
        status: rawMessage.status,
      ),
    ];

    for (var index = 0; index < imageBlocks.length; index++) {
      final imageBlock = imageBlocks[index];
      final projectedMessageId = imageBlocks.length == 1
          ? '${rawMessage.id}__proj_01_image'
          : '${rawMessage.id}__proj_${(index + 1).toString().padLeft(2, '0')}_image';
      projected.add(
        Message.fromBlocks(
          id: projectedMessageId,
          role: rawMessage.role,
          createdAt: rawMessage.createdAt,
          status: rawMessage.status,
          blocks: <MessageBlock>[
            ImageBlock(
              id: '${projectedMessageId}__b0_image',
              createdAt: rawMessage.createdAt,
              messageId: projectedMessageId,
              url: imageBlock.url,
              localPath: imageBlock.localPath,
              base64: imageBlock.base64,
              width: imageBlock.width,
              height: imageBlock.height,
              prompt: imageBlock.prompt,
              generationSnapshot: imageBlock.generationSnapshot,
              versions: imageBlock.versions,
              activeVersionIndex: imageBlock.activeVersionIndex,
              status: imageBlock.status,
            ),
          ],
        ),
      );
    }

    return projected;
  }

  List<Message> _applyStoredSupplementInsertOps(
    List<Message> baseMessages,
    List<StoredSupplementInsertOp> insertOps,
    Message rawMessage,
  ) {
    if (insertOps.isEmpty) {
      return baseMessages;
    }
    baseMessages = _splitAtSupplementAnchors(baseMessages, insertOps);
    if (baseMessages.isEmpty) {
      return <Message>[
        for (final (index, op) in insertOps.indexed)
          if (_buildMessageFromStoredSupplementOp(op, rawMessage, index)
              case final message?)
            message,
      ];
    }

    final textChunkLengths = <int>[
      for (final message in baseMessages)
        _normalizedTextLength(_extractText(message)),
    ];
    final slotMessages = <int, List<Message>>{};
    for (final (index, op) in insertOps.indexed) {
      final message = _buildMessageFromStoredSupplementOp(
        op,
        rawMessage,
        index,
      );
      if (message == null) {
        continue;
      }
      final slot = _resolveSupplementInsertSlot(
        textChunkLengths: textChunkLengths,
        textCharsBefore: op.textCharsBefore,
        forceAppendToTail: op.forceAppendToTail,
      );
      (slotMessages[slot] ??= <Message>[]).add(message);
    }

    final rebuilt = <Message>[...?slotMessages[0]];
    for (var index = 0; index < baseMessages.length; index += 1) {
      rebuilt.add(baseMessages[index]);
      rebuilt.addAll(slotMessages[index + 1] ?? const <Message>[]);
    }
    return rebuilt;
  }

  /// A stored media anchor can fall inside a merged text bubble. Split only at
  /// those semantic positions, not at punctuation or frontend chunk boundaries.
  List<Message> _splitAtSupplementAnchors(
    List<Message> messages,
    List<StoredSupplementInsertOp> ops,
  ) {
    final anchors = {
      for (final op in ops)
        if (!op.forceAppendToTail) op.textCharsBefore,
    };
    final result = <Message>[];
    var consumed = 0;
    final whitespace = RegExp(r'\s');
    for (final message in messages) {
      final text = _extractText(message);
      final length = _normalizedTextLength(text);
      final cuts = [
        for (final anchor in anchors)
          if (anchor > consumed && anchor < consumed + length)
            anchor - consumed,
      ]..sort();
      consumed += length;
      if (cuts.isEmpty) {
        result.add(message);
        continue;
      }
      var normalized = 0;
      var start = 0;
      var cutIndex = 0;
      final parts = <String>[];
      for (
        var index = 0;
        index < text.length && cutIndex < cuts.length;
        index++
      ) {
        if (!whitespace.hasMatch(text[index])) normalized++;
        if (normalized == cuts[cutIndex]) {
          parts.add(text.substring(start, index + 1));
          start = index + 1;
          cutIndex++;
        }
      }
      parts.add(text.substring(start));
      for (final (index, part) in parts.indexed) {
        final id = index == 0 ? message.id : '${message.id}__part$index';
        result.add(
          message.copyWith(
            id: id,
            content: part.trim(),
            blocks: message.blocks == null
                ? null
                : [
                    if (index == 0)
                      for (final block in message.blocks!)
                        if (block is! TextBlock) block,
                    TextBlock(
                      id: '${id}__text',
                      messageId: id,
                      content: part.trim(),
                      createdAt: message.createdAt,
                    ),
                  ],
          ),
        );
      }
    }
    return result;
  }

  Message? _buildMessageFromStoredSupplementOp(
    StoredSupplementInsertOp op,
    Message rawMessage,
    int index,
  ) {
    final id = op.legacyMessageId ?? '${rawMessage.id}__proj_supplement_${index}_${op.kind}';
    switch (op.kind) {
      case 'image':
        final localPath = op.localPath?.trim();
        if ((localPath == null || localPath.isEmpty) &&
            op.versions.isEmpty && op.status != BlockStatus.error) {
          return null;
        }
        final image = ImageBlock(
          id: op.legacyBlockId ?? '${id}__b0_image',
          createdAt: rawMessage.createdAt,
          messageId: id,
          localPath: op.versions.isEmpty
              ? localPath : op.versions[op.activeVersionIndex].localPath,
          url: op.versions.isEmpty
              ? null : op.versions[op.activeVersionIndex].url,
          base64: op.versions.isEmpty
              ? null : op.versions[op.activeVersionIndex].base64,
          width: op.width, height: op.height,
          prompt: op.prompt,
          generationSnapshot: op.generationSnapshot,
          versions: op.versions,
          activeVersionIndex: op.activeVersionIndex,
          status: op.status,
        );
        return _projectPassthroughMessage(
          Message.fromBlocks(
            id: id,
            role: 'assistant',
            blocks: <MessageBlock>[
              op.versions.isEmpty
                  ? image : image.withActiveVersion(op.activeVersionIndex),
            ],
            createdAt: rawMessage.createdAt,
            status: 'sent',
          ),
        );
      case 'audio':
        final audioUrl = op.audioUrl?.trim();
        if (audioUrl == null || audioUrl.isEmpty) {
          return null;
        }
        return _projectPassthroughMessage(
          Message.fromBlocks(
            id: id,
            role: 'assistant',
            blocks: <MessageBlock>[
              AudioBlock(
                id: op.legacyBlockId ?? '${id}__b0_audio',
                createdAt: rawMessage.createdAt,
                messageId: id,
                url: audioUrl,
                text: op.text?.trim().isNotEmpty ?? false
                    ? op.text!.trim()
                    : null,
                unread: op.unread,
              ),
            ],
            createdAt: rawMessage.createdAt,
            status: 'sent',
          ),
        );
    }
    return null;
  }
}

int _normalizedTextLength(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').length;

String _extractText(Message message) {
  final blocks = message.blocks;
  if (blocks != null && blocks.isNotEmpty) {
    final text =
        blocks.whereType<TextBlock>().map((block) => block.content).join();
    if (text.trim().isNotEmpty) {
      return text;
    }
  }
  return message.content;
}

int _resolveSupplementInsertSlot({
  required List<int> textChunkLengths,
  required int textCharsBefore,
  required bool forceAppendToTail,
}) {
  if (forceAppendToTail) {
    return textChunkLengths.length;
  }
  if (textCharsBefore <= 0) return 0;
  var cumulative = 0;
  for (var index = 0; index < textChunkLengths.length; index += 1) {
    cumulative += textChunkLengths[index];
    if (textCharsBefore <= cumulative) {
      return index + 1;
    }
  }
  return textChunkLengths.length;
}

final chatFrontendMessageProjectionServiceProvider =
    Provider<ChatFrontendMessageProjectionService>(
  (ref) => const ChatFrontendMessageProjectionService(),
);
