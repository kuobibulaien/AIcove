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
      return _attachSourceMessageId(rawMessage.id, cachedProjected);
    }

    if (rawMessage.role != 'assistant') {
      final mixedProjection = _projectMixedImageMessage(rawMessage);
      if (mixedProjection.isNotEmpty) {
        return _attachSourceMessageId(rawMessage.id, mixedProjection);
      }
      return <Message>[_projectPassthroughMessage(rawMessage)];
    }

    if (payload != null) {
      final rebuilt = const ChatMessageProcessor().buildAssistantMessages(
        replyText: ChatMessageProjectionCodec.rawReplyText(payload) ??
            rawMessage.content,
        processedText: ChatMessageProjectionCodec.processedText(payload) ?? '',
        pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
        contents: ChatMessageProjectionCodec.pluginContents(payload),
        toolCalls: ChatMessageProjectionCodec.toolCalls(payload),
        rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
      );
      if (rebuilt.messages.isNotEmpty) {
        return _attachSourceMessageId(rawMessage.id, rebuilt.messages);
      }
    }

    final mixedProjection = _projectMixedImageMessage(rawMessage);
    if (mixedProjection.isNotEmpty) {
      return _attachSourceMessageId(rawMessage.id, mixedProjection);
    }

    return <Message>[_projectPassthroughMessage(rawMessage)];
  }

  Message _projectPassthroughMessage(Message message) {
    return message.copyWith(
      sourceMessageId: message.sourceMessageId ?? message.id,
      rawPayload: null,
    );
  }

  List<Message> _attachSourceMessageId(
    String sourceMessageId,
    List<Message> messages,
  ) {
    return <Message>[
      for (final message in messages)
        message.copyWith(
          sourceMessageId: sourceMessageId,
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
}

final chatFrontendMessageProjectionServiceProvider =
    Provider<ChatFrontendMessageProjectionService>(
  (ref) => const ChatFrontendMessageProjectionService(),
);
