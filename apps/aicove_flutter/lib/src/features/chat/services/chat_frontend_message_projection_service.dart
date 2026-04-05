library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/message_block.dart';
import '../domain/message.dart';
import 'chat_message_processor.dart';
import 'chat_message_projection_codec.dart';

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
    final payload = rawMessage.rawPayload;
    final cachedProjected =
        ChatMessageProjectionCodec.projectedMessages(payload);
    if (cachedProjected.isNotEmpty) {
      return _normalizeProjectionFromRawMessage(rawMessage, cachedProjected);
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
          replyText: ChatMessageProjectionCodec.rawReplyText(payload) ??
              rawMessage.content,
          processedText:
              ChatMessageProjectionCodec.processedText(payload) ?? '',
          pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
          contents: const [],
          toolAudioResults: const [],
          toolCalls: ChatMessageProjectionCodec.toolCalls(payload),
          rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
        );
        final rebuilt = _applyStoredSupplementInsertOps(
          rebuiltBase.messages,
          supplementInsertOps,
        );
        if (rebuilt.isNotEmpty) {
          return _normalizeProjectionFromRawMessage(rawMessage, rebuilt);
        }
      }
      final rebuilt = const ChatMessageProcessor().buildAssistantMessages(
        replyText: ChatMessageProjectionCodec.rawReplyText(payload) ??
            rawMessage.content,
        processedText: ChatMessageProjectionCodec.processedText(payload) ?? '',
        pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
        contents: ChatMessageProjectionCodec.pluginContents(payload),
        toolAudioResults: ChatMessageProjectionCodec.toolAudioResults(payload),
        toolCalls: ChatMessageProjectionCodec.toolCalls(payload),
        rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
      );
      if (rebuilt.messages.isNotEmpty) {
        return _normalizeProjectionFromRawMessage(
          rawMessage,
          rebuilt.messages,
        );
      }
    }

    final mixedProjection = _projectMixedImageMessage(rawMessage);
    if (mixedProjection.isNotEmpty) {
      return _normalizeProjectionFromRawMessage(rawMessage, mixedProjection);
    }

    return <Message>[_projectPassthroughMessage(rawMessage)];
  }

  Message _projectPassthroughMessage(Message message) {
    return message.copyWith(
      sourceMessageId: message.sourceMessageId ?? message.id,
      rawPayload: null,
    );
  }

  List<Message> _normalizeProjectionFromRawMessage(
    Message rawMessage,
    List<Message> messages,
  ) {
    return <Message>[
      for (final message in messages)
        message.copyWith(
          sourceMessageId: rawMessage.id,
          createdAt: rawMessage.createdAt,
          rawPayload: null,
        ),
    ];
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

    final textContent = textBlocks.map((block) => block.content.trim()).join(
          '\n\n',
        );
    if (textContent.isEmpty) {
      return const <Message>[];
    }

    final projected = <Message>[
      Message.text(
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
              messageId: projectedMessageId,
              url: imageBlock.url,
              localPath: imageBlock.localPath,
              base64: imageBlock.base64,
              width: imageBlock.width,
              height: imageBlock.height,
              prompt: imageBlock.prompt,
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
  ) {
    if (insertOps.isEmpty) {
      return baseMessages;
    }
    if (baseMessages.isEmpty) {
      return <Message>[
        for (final op in insertOps)
          if (_buildMessageFromStoredSupplementOp(op) case final message?)
            message,
      ];
    }

    final textChunkLengths = <int>[
      for (final message in baseMessages)
        _normalizedTextLength(_extractText(message)),
    ];
    final slotMessages = <int, List<Message>>{};
    for (final op in insertOps) {
      final message = _buildMessageFromStoredSupplementOp(op);
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

    final rebuilt = <Message>[
      ...?slotMessages[0],
    ];
    for (var index = 0; index < baseMessages.length; index += 1) {
      rebuilt.add(baseMessages[index]);
      rebuilt.addAll(slotMessages[index + 1] ?? const <Message>[]);
    }
    return rebuilt;
  }

  Message? _buildMessageFromStoredSupplementOp(StoredSupplementInsertOp op) {
    switch (op.kind) {
      case 'image':
        final localPath = op.localPath?.trim();
        if (localPath == null || localPath.isEmpty) {
          return null;
        }
        return _projectPassthroughMessage(
          Message.fromBlocks(
            id: 'img_${localPath.hashCode}_${op.textCharsBefore}',
            role: 'assistant',
            blocks: <MessageBlock>[
              ImageBlock(
                messageId: 'img_${localPath.hashCode}_${op.textCharsBefore}',
                localPath: localPath,
                prompt: op.prompt,
              ),
            ],
            createdAt: DateTime.now(),
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
            id: 'audio_${audioUrl.hashCode}_${op.textCharsBefore}',
            role: 'assistant',
            blocks: <MessageBlock>[
              AudioBlock(
                messageId: 'audio_${audioUrl.hashCode}_${op.textCharsBefore}',
                url: audioUrl,
                text: op.text?.trim().isNotEmpty ?? false
                    ? op.text!.trim()
                    : null,
              ),
            ],
            createdAt: DateTime.now(),
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
