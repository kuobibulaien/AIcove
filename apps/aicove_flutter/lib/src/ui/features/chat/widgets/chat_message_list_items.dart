import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';

abstract class ChatMessageListItem {
  const ChatMessageListItem();
}

class ChatMessageItem extends ChatMessageListItem {
  const ChatMessageItem(
    this.message, {
    this.showCorner = false,
    this.showAvatar = true,
  });

  final Message message;
  final bool showCorner;
  final bool showAvatar;
}

class ChatChunkedMessageItem extends ChatMessageListItem {
  const ChatChunkedMessageItem({
    required this.originalMessage,
    required this.chunkText,
    required this.chunkIndex,
    required this.totalChunks,
    this.showCorner = false,
    this.showAvatar = true,
  });

  final Message originalMessage;
  final String chunkText;
  final int chunkIndex;
  final int totalChunks;
  final bool showCorner;
  final bool showAvatar;
}

class ChatTimeDividerItem extends ChatMessageListItem {
  const ChatTimeDividerItem(
    this.time, {
    required this.associatedMessageId,
  });

  final DateTime time;
  final String associatedMessageId;
}

class ChatNewTopicDividerItem extends ChatMessageListItem {
  const ChatNewTopicDividerItem({required this.associatedMessageId});

  final String associatedMessageId;
}

List<ChatMessageListItem> buildChatMessageListItems({
  required List<Message> messages,
  MessageFormatConfig? config,
}) {
  final items = <ChatMessageListItem>[];
  final enableChunking = config?.enableChunking ?? true;

  for (var index = 0; index < messages.length; index++) {
    final currentMessage = messages[index];
    var hasTimeDivider = false;

    if (index == 0) {
      items.add(
        ChatTimeDividerItem(
          currentMessage.createdAt,
          associatedMessageId: currentMessage.id,
        ),
      );
      hasTimeDivider = true;
    } else {
      final previousMessage = messages[index - 1];
      final timeDiff =
          currentMessage.createdAt.difference(previousMessage.createdAt);
      if (timeDiff.inMinutes >= 20) {
        items.add(
          ChatTimeDividerItem(
            currentMessage.createdAt,
            associatedMessageId: currentMessage.id,
          ),
        );
        hasTimeDivider = true;
      }
    }

    var showAvatar = true;
    if (!hasTimeDivider && index > 0) {
      final previousMessage = messages[index - 1];
      if (previousMessage.role == currentMessage.role) {
        showAvatar = false;
      }
    }

    final chunkSourceText = _resolveChunkSourceText(currentMessage);
    final shouldChunk = enableChunking &&
        currentMessage.role == 'assistant' &&
        currentMessage.status != 'sending' &&
        !_hasNonTextBlocks(currentMessage) &&
        chunkSourceText.trim().isNotEmpty;

    if (shouldChunk && config != null) {
      final chunks =
          MessageFormatter.formatAndChunkText(chunkSourceText, config);
      if (chunks.length > 1) {
        for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
          items.add(
            ChatChunkedMessageItem(
              originalMessage: currentMessage,
              chunkText: chunks[chunkIndex],
              chunkIndex: chunkIndex,
              totalChunks: chunks.length,
              showCorner: _resolveShowCornerForChunk(
                messages: messages,
                currentMessageIndex: index,
                chunkIndex: chunkIndex,
                chunkCount: chunks.length,
              ),
              showAvatar: chunkIndex == 0 && showAvatar,
            ),
          );
        }
        continue;
      }
    }

    items.add(
      ChatMessageItem(
        currentMessage,
        showCorner: _resolveShowCornerForMessage(
          messages: messages,
          currentMessageIndex: index,
        ),
        showAvatar: showAvatar,
      ),
    );
  }

  return items;
}

List<ImagePreviewItem> collectChatMessageListImages(List<Message> messages) {
  final result = <ImagePreviewItem>[];
  for (final message in messages) {
    final blocks = message.blocks;
    if (blocks == null) continue;
    for (final block in blocks) {
      final provider = resolveChatMessageListImageProvider(block);
      if (provider == null) continue;
      final isSticker = block is EmojiBlock;
      final heroTag = isSticker ? 'sticker_${block.id}' : 'image_${block.id}';
      result.add(ImagePreviewItem(provider: provider, heroTag: heroTag));
    }
  }
  return result;
}

ImageProvider? resolveChatMessageListImageProvider(MessageBlock block) {
  if (block is EmojiBlock) {
    final path = block.path.trim().replaceAll('\\', '/');
    if (path.isEmpty) return null;
    final isNetwork = path.startsWith('http://') || path.startsWith('https://');
    final isAsset = path.startsWith('assets/') || path.startsWith('packages/');
    if (isNetwork) return CachedNetworkImageProvider(path);
    if (isAsset) return AssetImage(path);
    return FileImage(File(path));
  }
  if (block is ImageBlock) {
    if (block.localPath != null && block.localPath!.isNotEmpty) {
      return FileImage(File(block.localPath!));
    }
    if (block.url != null && block.url!.isNotEmpty) {
      return CachedNetworkImageProvider(block.url!);
    }
    if (block.base64 != null && block.base64!.isNotEmpty) {
      final dataBytes =
          decodeDataImage('data:image/jpeg;base64,${block.base64}');
      if (dataBytes != null) return MemoryImage(dataBytes);
    }
    return null;
  }
  return null;
}

bool _hasNonTextBlocks(Message message) {
  final blocks = message.blocks;
  return blocks?.any((block) => block is! TextBlock) ?? false;
}

String _resolveChunkSourceText(Message message) {
  final blocks = message.blocks;
  if (blocks == null || blocks.isEmpty) {
    return message.content;
  }
  return blocks
      .whereType<TextBlock>()
      .map((block) => block.content)
      .join('\n\n');
}

bool _resolveShowCornerForMessage({
  required List<Message> messages,
  required int currentMessageIndex,
}) {
  if (currentMessageIndex + 1 >= messages.length) {
    return false;
  }
  final currentMessage = messages[currentMessageIndex];
  final nextMessage = messages[currentMessageIndex + 1];
  if (nextMessage.role != currentMessage.role) {
    return false;
  }
  final timeDiff = nextMessage.createdAt.difference(currentMessage.createdAt);
  return timeDiff.inMinutes < 20;
}

bool _resolveShowCornerForChunk({
  required List<Message> messages,
  required int currentMessageIndex,
  required int chunkIndex,
  required int chunkCount,
}) {
  if (chunkIndex < chunkCount - 1) {
    return true;
  }
  return _resolveShowCornerForMessage(
    messages: messages,
    currentMessageIndex: currentMessageIndex,
  );
}
