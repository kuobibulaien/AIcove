import '../../../../features/conversation_state/domain/mvu_content.dart';
import 'dart:collection';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/message_block.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/content_tags/domain/tag_presentation.dart';
import '../../../../features/dialogue_options/domain/dialogue_options.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
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
    this.fold,
  });

  final Message originalMessage;
  final String chunkText;
  final int chunkIndex;
  final int totalChunks;
  final bool showCorner;
  final bool showAvatar;

  /// 非空时这一段是折叠气泡（预设语义标签投影，ADR0046）。
  final TagFoldPart? fold;
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

/// Selection follows displayed bubbles, including legacy text chunks.
Message? chatListItemSelectionMessage(ChatMessageListItem item) {
  if (item is ChatMessageItem) {
    return MessageBubble.hasVisibleContent(item.message) ? item.message : null;
  }
  if (item is ChatChunkedMessageItem) {
    final message = item.originalMessage;
    return Message(
      id: '${message.id}_chunk_${item.chunkIndex}',
      role: message.role,
      content: item.chunkText,
      createdAt: message.createdAt,
      status: message.status,
    );
  }
  return null;
}

List<ChatMessageListItem> buildChatMessageListItems({
  required List<Message> messages,
  MessageFormatConfig? config,
  TagPresentationMap tagPresentation = const {},
}) {
  final items = <ChatMessageListItem>[];
  final enableChunking = config?.enableChunking ?? true;

  for (var index = 0; index < messages.length; index++) {
    final currentMessage = stripDialogueOptionsForDisplay(
      stripMvuUpdatesForDisplay(messages[index]),
    );
    // 只有选项的回复段交给对话选项气泡展示，不留空气泡。
    if (!identical(currentMessage, messages[index]) &&
        currentMessage.status != 'sending' &&
        _resolveChunkSourceText(currentMessage).trim().isEmpty &&
        !_hasNonTextBlocks(currentMessage)) {
      continue;
    }
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

    // 预设语义标签：折叠标签单独成折叠气泡，正文标签去壳，其余照常分段。
    final tagParts = currentMessage.role == 'assistant' &&
            !_hasNonTextBlocks(currentMessage)
        ? _projectTagParts(
            chunkSourceText,
            tagPresentation,
            // 生成中只用发送前定好的映射，不临时判断未知外壳。
            allowUnwrap: currentMessage.status != 'sending',
          )
        : null;
    if (tagParts != null) {
      final pieces = <(String, TagFoldPart?)>[
        for (final part in tagParts)
          ...switch (part) {
            TagFoldPart() => [(part.content, part)],
            TagBodyPart(:final text) => [
                for (final chunk in shouldChunk && config != null
                    ? _chunkTextMemoized(text, config)
                    : [text])
                  (chunk, null),
              ],
          },
      ];
      for (var pieceIndex = 0; pieceIndex < pieces.length; pieceIndex++) {
        items.add(
          ChatChunkedMessageItem(
            originalMessage: currentMessage,
            chunkText: pieces[pieceIndex].$1,
            chunkIndex: pieceIndex,
            totalChunks: pieces.length,
            showCorner: _resolveShowCornerForChunk(
              messages: messages,
              currentMessageIndex: index,
              chunkIndex: pieceIndex,
              chunkCount: pieces.length,
            ),
            showAvatar: pieceIndex == 0 && showAvatar,
            fold: pieces[pieceIndex].$2,
          ),
        );
      }
      continue;
    }

    if (shouldChunk && config != null) {
      final chunks = _chunkTextMemoized(chunkSourceText, config);
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
      final dataBytes = decodeInlineBase64Image(block.base64);
      if (dataBytes != null) return MemoryImage(dataBytes);
    }
    return null;
  }
  return null;
}

/// 已生成完的助手回复里出现、映射里没有的顶层标签名（ADR0048，“聊天中发现”）。
/// 输入角色名（user/char 等）是模型回显，不提示。
Set<String> collectUnknownReplyTags(
  List<Message> messages,
  TagPresentationMap tagPresentation,
) {
  final names = <String>{};
  for (final message in messages) {
    if (message.role != 'assistant' || message.status == 'sending') continue;
    final text = _resolveChunkSourceText(message);
    if (!text.contains('<')) continue;
    for (final tag in findUnknownTopLevelTags(text, tagPresentation)) {
      if (!_echoedRoleTags.contains(tag.name)) names.add(tag.name);
    }
  }
  return names;
}

const Set<String> _echoedRoleTags = {
  'user', 'char', 'system', 'assistant', 'human', 'model',
};

/// 文本里有映射到的语义标签时返回投影片段；没有可处理的标签时返回 null，
/// 走原来的整条／分段显示。
List<TagDisplayPart>? _projectTagParts(
  String text,
  TagPresentationMap tagPresentation, {
  required bool allowUnwrap,
}) {
  if (!text.contains('<')) return null;
  // 无损兜底（ADR0048）：只剩一个未知外层标签且包着主要内容时去壳当正文。
  final wrapper =
      allowUnwrap ? soleUnknownBodyWrapper(text, tagPresentation) : null;
  final map = wrapper == null
      ? tagPresentation
      : {
          ...tagPresentation,
          wrapper: const TagPresentationEntry(TagPresentation.body, '正文'),
        };
  if (map.isEmpty) return null;
  final parts = projectTagPresentation(text, map);
  if (parts.isEmpty) return null;
  final unchanged = parts.length == 1 &&
      parts.single is TagBodyPart &&
      (parts.single as TagBodyPart).text == text.trim();
  return unchanged ? null : parts;
}

/// 消息里有文字以外的可见块（语音、图片、文件等）时整条显示，不分段也不投影。
/// 工具块不显示（如生图完成后补在锚点文字消息上的图片上下文），不能让它
/// 挡住标签投影，否则预设正文标签会原样露出。
bool _hasNonTextBlocks(Message message) {
  final blocks = message.blocks;
  return blocks?.any((block) => block is! TextBlock && block is! ToolBlock) ??
      false;
}

// 分段是多组正则＋颗文字保护的纯函数；列表每次结构变化（历史翻页、流式
// 结构事件）都对全部消息重建列表项，未变化的旧消息不该重复付费。
// 按（格式签名, 原文）记忆化，原文引用已由 message 持有，键不额外占大内存。
const int _kChunkMemoMaxEntries = 512;
final LinkedHashMap<String, List<String>> _chunkMemo =
    LinkedHashMap<String, List<String>>();
String? _chunkMemoFormatSignature;

List<String> _chunkTextMemoized(String text, MessageFormatConfig config) {
  final formatSignature = buildMessageFormatProjectionSignature(config);
  if (_chunkMemoFormatSignature != formatSignature) {
    _chunkMemo.clear();
    _chunkMemoFormatSignature = formatSignature;
  }
  final cached = _chunkMemo.remove(text);
  if (cached != null) {
    _chunkMemo[text] = cached;
    return cached;
  }
  final chunks = List<String>.unmodifiable(
    MessageFormatter.formatAndChunkText(text, config),
  );
  _chunkMemo[text] = chunks;
  while (_chunkMemo.length > _kChunkMemoMaxEntries) {
    _chunkMemo.remove(_chunkMemo.keys.first);
  }
  return chunks;
}

@visibleForTesting
void clearChatMessageListChunkMemo() {
  _chunkMemo.clear();
  _chunkMemoFormatSignature = null;
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
