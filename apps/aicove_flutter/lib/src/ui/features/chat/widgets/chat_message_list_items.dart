import '../../../../features/conversation_state/domain/mvu_content.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/media/media_asset.dart';
import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/chat/domain/chat_timeline_deletion.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/domain/tool_call_label.dart';
import '../../../../features/content_tags/domain/tag_presentation.dart';
import '../../../../features/dialogue_options/domain/dialogue_options.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/services/chat_message_processor.dart';
import '../../../../features/chat/services/chat_request_message_builder.dart';
import '../../../../features/stickers/sticker_library.dart';
import '../../../../features/task_agent/application/delegate_task_plugin.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../voice_call/widgets/voice_call_live_messages.dart'
    show voiceCallLiveMessagePrefix;

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
  ChatChunkedMessageItem({
    required this.originalMessage,
    required this.chunkText,
    required this.chunkIndex,
    required this.totalChunks,
    String? pieceId,
    List<String>? mergedMessageIds,
    this.showCorner = false,
    this.showAvatar = true,
    this.fold,
  }) : pieceId =
           pieceId ??
           ChatTimelinePieceId.compose(originalMessage.id, 'chunk_$chunkIndex'),
       mergedMessageIds = List<String>.unmodifiable(
         mergedMessageIds ?? <String>[originalMessage.id],
       );

  final Message originalMessage;
  final String chunkText;
  final int chunkIndex;
  final int totalChunks;
  final String pieceId;
  final List<String> mergedMessageIds;
  final bool showCorner;
  final bool showAvatar;

  /// 非空时这一段是折叠气泡（预设语义标签投影，ADR0046）。
  final TagFoldPart? fold;
}

/// The quiet waiting line for a `delegate_task` errand. It renders outside
/// any bubble and collapses once the task settles; the persona's own reply
/// is what tells the user the result.
class ChatTaskRunningItem extends ChatMessageListItem {
  const ChatTaskRunningItem(this.taskId, {required this.associatedMessageId});

  final String taskId;
  final String associatedMessageId;
}

/// How a reply ended when it did not finish normally. Written by the send
/// pipeline into the turn's last assistant message as
/// `rawPayload['runStatus']`; a completed reply carries no key.
enum ChatRunStatus {
  truncated('回复达到长度上限，被截断了'),
  waitingForUser('在等你回答，回复后接着做'),
  cancelled('已停止'),
  failed('出错了，没有做完');

  const ChatRunStatus(this.label);

  final String label;

  static ChatRunStatus? of(Message message) {
    if (message.role != 'assistant' || message.status == 'sending') {
      return null;
    }
    final raw = message.rawPayload?['runStatus'];
    for (final status in values) {
      if (status.name == raw) return status;
    }
    return null;
  }
}

/// The quiet line under a reply that did not finish normally, so a cut-off
/// or stopped run never reads as a finished answer.
class ChatRunStatusItem extends ChatMessageListItem {
  ChatRunStatusItem(
    this.status, {
    required this.message,
    String? associatedMessageId,
    this.standalone = false,
  }) : associatedMessageId = associatedMessageId ?? message.id;

  final ChatRunStatus status;
  final Message message;
  final String associatedMessageId;
  final bool standalone;
}

/// The quiet action row under a finished assistant reply in document mode:
/// copy, quote, retry and when it was sent. One reply turn may span several
/// messages (tool rounds, split replies); [message] is the last of them.
/// A reply still generating keeps the row's space but hides it, so the
/// list does not grow under the reader the moment the reply finishes.
class ChatReplyActionsItem extends ChatMessageListItem {
  const ChatReplyActionsItem(
    this.message, {
    required this.messageIds,
    required this.copyText,
    required this.finished,
  });

  final Message message;
  final bool finished;

  /// Every message of the turn, so hovering any of them reveals this row.
  final List<String> messageIds;

  final String copyText;
}

class ChatTimeDividerItem extends ChatMessageListItem {
  const ChatTimeDividerItem(this.time, {required this.associatedMessageId});

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
    if (item.message.id.startsWith(voiceCallLiveMessagePrefix)) return null;
    return MessageBubble.hasVisibleContent(item.message) ? item.message : null;
  }
  if (item is ChatChunkedMessageItem) {
    if (item.originalMessage.id.startsWith(voiceCallLiveMessagePrefix)) {
      return null;
    }
    return chatChunkDisplayMessage(item);
  }
  if (item is ChatRunStatusItem) {
    if (!item.standalone ||
        item.message.status == 'sending' ||
        item.message.id.startsWith(voiceCallLiveMessagePrefix)) {
      return null;
    }
    return Message(
      id: item.message.id,
      role: item.message.role,
      content: '[${item.status.label}]',
      createdAt: item.message.createdAt,
      status: item.message.status,
      sourceMessageId: item.message.sourceMessageId,
    );
  }
  return null;
}

/// The message a chunk bubble renders; fold chunks carry a thinking block so
/// the bubble draws the fold component (ADR0046).
Message chatChunkDisplayMessage(ChatChunkedMessageItem item) {
  final message = item.originalMessage;
  final chunkId = item.pieceId;
  final fold = item.fold;
  return Message(
    id: chunkId,
    role: message.role,
    content: item.chunkText,
    blocks: fold == null
        ? null
        : [
            ThinkingBlock(
              id: '${chunkId}_fold',
              messageId: chunkId,
              content: fold.content,
              title: fold.title,
              status: fold.closed ? BlockStatus.success : BlockStatus.streaming,
            ),
          ],
    createdAt: message.createdAt,
    status: message.status,
    sourceMessageId: message.sourceMessageIdOrSelf,
  );
}

typedef _GeneratedPiece = ({
  String pieceId,
  String text,
  TagFoldPart? fold,
  bool isThinkingFold,
});

List<ChatMessageListItem> buildChatMessageListItems({
  required List<Message> messages,
  MessageFormatConfig? config,
  TagPresentationMap tagPresentation = const {},
  bool showTimeDividers = true,
  bool showThinkingFolds = true,
  bool showToolCallFolds = false,
  bool showReplyActions = false,
  Set<String> hiddenPieceIds = const <String>{},
}) {
  final items = <ChatMessageListItem>[];
  final enableChunking = config?.enableChunking ?? true;

  Message? previousShown;
  for (var index = 0; index < messages.length; index++) {
    // 后台任务回执只给人设转告用，聊天里不显示（ADR0088 §4）。
    if (_isTaskReceipt(messages[index])) continue;
    final start = index;
    var source = messages[index];
    final mergedMessageIds = <String>[source.id];
    // 连着几轮只调工具不说话时，相邻的工具调用收拢成一个过程折叠段。
    if (showToolCallFolds && _isToolOnly(source)) {
      final blocks = [...source.blocks!];
      while (index + 1 < messages.length && _isToolOnly(messages[index + 1])) {
        index++;
        mergedMessageIds.add(messages[index].id);
        blocks.addAll(messages[index].blocks!);
      }
      if (index > start) {
        source = source.copyWith(
          blocks: blocks,
          rawPayload: messages[index].rawPayload,
        );
      }
    }
    final currentMessage = stripDialogueOptionsForDisplay(
      stripMvuUpdatesForDisplay(source),
      tagPresentation: tagPresentation,
    );
    final runStatus = ChatRunStatus.of(currentMessage);
    final taskIds = _delegateTaskIds(currentMessage).toList(growable: false);
    final hasRunningItems = taskIds.isNotEmpty || runStatus != null;
    List<ChatMessageListItem> buildRunningItems({required bool standalone}) => [
      for (final taskId in taskIds)
        ChatTaskRunningItem(taskId, associatedMessageId: currentMessage.id),
      if (runStatus != null)
        ChatRunStatusItem(
          runStatus,
          message: currentMessage,
          standalone: standalone,
        ),
    ];

    final chunkSourceText = _resolveChunkSourceText(currentMessage);
    final projectable =
        currentMessage.role == 'assistant' &&
        !_hasNonTextBlocks(currentMessage);
    final thinkingFolds = projectable
        ? _modelThinkingFolds(currentMessage)
        : const <TagFoldPart>[];
    final toolFolds = projectable && showToolCallFolds
        ? _toolCallFolds(currentMessage)
        : const <TagFoldPart>[];
    final hasVisibleProcessFolds =
        (showThinkingFolds && thinkingFolds.isNotEmpty) || toolFolds.isNotEmpty;

    // 只有派活调用或运行状态的那一轮不画空气泡，只留等待条／状态行。
    if (hasRunningItems &&
        currentMessage.status != 'sending' &&
        chunkSourceText.trim().isEmpty &&
        !_hasNonTextBlocks(currentMessage) &&
        !hasVisibleProcessFolds) {
      items.addAll(buildRunningItems(standalone: true));
      continue;
    }
    // 只有选项的回复段交给对话选项气泡展示，不留空气泡。
    if (!identical(currentMessage, source) &&
        currentMessage.status != 'sending' &&
        chunkSourceText.trim().isEmpty &&
        !_hasNonTextBlocks(currentMessage) &&
        !hasVisibleProcessFolds) {
      continue;
    }

    // 时间小气泡属于时间感知插件：插件关掉时不显示，但隔了很久的消息照样重新露头像。
    final hasTimeDivider =
        start == 0 ||
        currentMessage.createdAt
                .difference(messages[start - 1].createdAt)
                .inMinutes >=
            20;
    bool computeShowAvatar() {
      final result =
          hasTimeDivider ||
          previousShown == null ||
          previousShown!.role != currentMessage.role;
      previousShown = currentMessage;
      if (hasTimeDivider && showTimeDividers) {
        items.add(
          ChatTimeDividerItem(
            currentMessage.createdAt,
            associatedMessageId: currentMessage.id,
          ),
        );
      }
      return result;
    }

    final shouldChunk =
        enableChunking &&
        currentMessage.role == 'assistant' &&
        currentMessage.status != 'sending' &&
        !_hasNonTextBlocks(currentMessage) &&
        chunkSourceText.trim().isNotEmpty;

    // 预设语义标签：折叠标签单独成折叠气泡，正文标签去壳，其余照常分段。
    final rawTagParts = projectable
        ? _projectTagParts(
            chunkSourceText,
            tagPresentation,
            // 生成中只用发送前定好的映射，不临时判断未知外壳。
            allowUnwrap: currentMessage.status != 'sending',
          )
        : null;
    final hasAnyProcessFolds =
        thinkingFolds.isNotEmpty || toolFolds.isNotEmpty;

    if (hasAnyProcessFolds || rawTagParts != null) {
      final allPieces = <_GeneratedPiece>[
        for (var i = 0; i < thinkingFolds.length; i++)
          (
            pieceId: ChatTimelinePieceId.compose(
              currentMessage.id,
              'fold_thinking_$i',
            ),
            text: thinkingFolds[i].content,
            fold: thinkingFolds[i],
            isThinkingFold: true,
          ),
        for (var i = 0; i < toolFolds.length; i++)
          (
            pieceId: ChatTimelinePieceId.compose(
              currentMessage.id,
              'fold_tool_$i',
            ),
            text: toolFolds[i].content,
            fold: toolFolds[i],
            isThinkingFold: false,
          ),
      ];
      final bodyParts =
          rawTagParts ??
          [
            if (chunkSourceText.trim().isNotEmpty)
              TagBodyPart(chunkSourceText),
          ];
      var tagFoldIndex = 0;
      var bodyIndex = 0;
      for (final part in bodyParts) {
        switch (part) {
          case TagFoldPart():
            allPieces.add((
              pieceId: ChatTimelinePieceId.compose(
                currentMessage.id,
                'fold_tag_${tagFoldIndex++}',
              ),
              text: part.content,
              fold: part,
              isThinkingFold: _isThinkingFoldTitle(part.title),
            ));
          case TagBodyPart(:final text):
            final bodyChunks = shouldChunk && config != null
                ? _chunkTextMemoized(text, config)
                : [text];
            for (final chunk in bodyChunks) {
              allPieces.add((
                pieceId: ChatTimelinePieceId.compose(
                  currentMessage.id,
                  'body_${bodyIndex++}',
                ),
                text: chunk,
                fold: null,
                isThinkingFold: false,
              ));
            }
        }
      }
      final visiblePieces = [
        for (final piece in allPieces)
          if ((showThinkingFolds || !piece.isThinkingFold) &&
              !hiddenPieceIds.contains(piece.pieceId))
            piece,
      ];
      if (visiblePieces.isEmpty) {
        if (hasRunningItems) {
          items.addAll(buildRunningItems(standalone: true));
        }
        continue;
      }
      final showAvatar = computeShowAvatar();
      for (var pieceIndex = 0; pieceIndex < visiblePieces.length; pieceIndex++) {
        final piece = visiblePieces[pieceIndex];
        items.add(
          ChatChunkedMessageItem(
            originalMessage: currentMessage,
            chunkText: piece.text,
            chunkIndex: pieceIndex,
            totalChunks: visiblePieces.length,
            pieceId: piece.pieceId,
            mergedMessageIds: mergedMessageIds,
            showCorner: _resolveShowCornerForChunk(
              messages: messages,
              currentMessageIndex: index,
              chunkIndex: pieceIndex,
              chunkCount: visiblePieces.length,
            ),
            showAvatar: pieceIndex == 0 && showAvatar,
            fold: piece.fold,
          ),
        );
      }
      items.addAll(buildRunningItems(standalone: false));
      continue;
    }

    if (shouldChunk && config != null) {
      final chunks = _chunkTextMemoized(chunkSourceText, config);
      if (chunks.length > 1) {
        final visiblePieces = <(String, String)>[
          for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++)
            if (ChatTimelinePieceId.compose(
                  currentMessage.id,
                  'body_$chunkIndex',
                )
                case final pieceId when !hiddenPieceIds.contains(pieceId))
              (pieceId, chunks[chunkIndex]),
        ];
        if (visiblePieces.isEmpty) {
          if (hasRunningItems) {
            items.addAll(buildRunningItems(standalone: true));
          }
          continue;
        }
        final showAvatar = computeShowAvatar();
        for (
          var pieceIndex = 0;
          pieceIndex < visiblePieces.length;
          pieceIndex++
        ) {
          items.add(
            ChatChunkedMessageItem(
              originalMessage: currentMessage,
              chunkText: visiblePieces[pieceIndex].$2,
              chunkIndex: pieceIndex,
              totalChunks: visiblePieces.length,
              pieceId: visiblePieces[pieceIndex].$1,
              mergedMessageIds: mergedMessageIds,
              showCorner: _resolveShowCornerForChunk(
                messages: messages,
                currentMessageIndex: index,
                chunkIndex: pieceIndex,
                chunkCount: visiblePieces.length,
              ),
              showAvatar: pieceIndex == 0 && showAvatar,
            ),
          );
        }
        items.addAll(buildRunningItems(standalone: false));
        continue;
      }
    }

    final showAvatar = computeShowAvatar();
    final hasVisibleBubble = MessageBubble.hasVisibleContent(currentMessage);
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
    items.addAll(buildRunningItems(standalone: !hasVisibleBubble));
  }

  return showReplyActions ? _withReplyActions(items) : items;
}

enum _DeletableEntryKind { message, chunk, standaloneRunStatus }

class _DeletableListEntry {
  const _DeletableListEntry({
    required this.selectionId,
    required this.parentMessageId,
    required this.originalSourceMessageId,
    required this.mergedMessageIds,
    required this.rawMessageIds,
    required this.isPrimaryBody,
    required this.isToolOnlyFold,
    required this.kind,
  });

  final String selectionId;
  final String parentMessageId;
  final String? originalSourceMessageId;
  final List<String> mergedMessageIds;
  final Set<String> rawMessageIds;
  final bool isPrimaryBody;
  final bool isToolOnlyFold;
  final _DeletableEntryKind kind;
}

bool _isThinkingOnly(Message message) {
  final blocks = message.blocks;
  return blocks != null &&
      blocks.isNotEmpty &&
      blocks.every((block) => block is ThinkingBlock);
}

/// Resolves user-selected timeline targets into canonical raw deletions vs.
/// local piece/projection hides, upgrading to canonical deletion whenever all
/// primary body items of a raw message are removed.
ChatTimelineDeletePlan resolveChatTimelineDeletePlan({
  required List<Message> windowMessages,
  required List<ChatMessageListItem> listItems,
  Set<String> stagedMessageIds = const <String>{},
  Iterable<String> targetSelectionIds = const <String>[],
  Iterable<String> turnAnchorMessageIds = const <String>[],
}) {
  final anchors = <String>[];
  final seenAnchors = <String>{};
  for (final rawAnchor in turnAnchorMessageIds) {
    final anchor = rawAnchor.trim();
    if (anchor.isEmpty || anchor.startsWith(voiceCallLiveMessagePrefix)) {
      continue;
    }
    if (seenAnchors.add(anchor)) anchors.add(anchor);
  }
  if (anchors.isNotEmpty) {
    return ChatTimelineDeletePlan(turnAnchorMessageIdsToDelete: anchors);
  }

  final resolvedStagedIds = <String>[];
  final seenStaged = <String>{};
  final remainingTargets = <String>{};
  for (final rawTarget in targetSelectionIds) {
    final target = rawTarget.trim();
    if (target.isEmpty || target.startsWith(voiceCallLiveMessagePrefix)) {
      continue;
    }
    if (stagedMessageIds.contains(target)) {
      if (seenStaged.add(target)) resolvedStagedIds.add(target);
    } else {
      remainingTargets.add(target);
    }
  }
  if (remainingTargets.isEmpty) {
    return ChatTimelineDeletePlan(stagedMessageIds: resolvedStagedIds);
  }

  final messageById = <String, Message>{
    for (final message in windowMessages) message.id: message,
  };
  String rawIdOfId(String id, {String? fallbackSourceId}) {
    final parentId = ChatTimelinePieceId.parentMessageIdOf(id) ?? id;
    final message = messageById[parentId] ?? messageById[id];
    return ChatTimelinePieceId.rawMessageIdOf(
      id,
      explicitSourceId: message?.sourceMessageId ?? fallbackSourceId,
    );
  }

  final entries = <_DeletableListEntry>[];
  for (final item in listItems) {
    if (item is ChatMessageItem) {
      final message = item.message;
      if (message.id.startsWith(voiceCallLiveMessagePrefix) ||
          !MessageBubble.hasVisibleContent(message) ||
          stagedMessageIds.contains(message.id)) {
        continue;
      }
      entries.add(
        _DeletableListEntry(
          selectionId: message.id,
          parentMessageId: message.id,
          originalSourceMessageId: message.sourceMessageId,
          mergedMessageIds: <String>[message.id],
          rawMessageIds: <String>{
            ChatTimelinePieceId.rawMessageIdOf(
              message.id,
              explicitSourceId: message.sourceMessageId,
            ),
          },
          isPrimaryBody: !_isToolOnly(message) && !_isThinkingOnly(message),
          isToolOnlyFold: false,
          kind: _DeletableEntryKind.message,
        ),
      );
    } else if (item is ChatChunkedMessageItem) {
      final original = item.originalMessage;
      if (original.id.startsWith(voiceCallLiveMessagePrefix) ||
          stagedMessageIds.contains(original.id)) {
        continue;
      }
      final rawIds = <String>{
        for (final mid in item.mergedMessageIds)
          rawIdOfId(
            mid,
            fallbackSourceId: mid == original.id
                ? original.sourceMessageId
                : null,
          ),
      };
      entries.add(
        _DeletableListEntry(
          selectionId: item.pieceId,
          parentMessageId: original.id,
          originalSourceMessageId: original.sourceMessageId,
          mergedMessageIds: item.mergedMessageIds,
          rawMessageIds: rawIds,
          isPrimaryBody: item.fold == null,
          isToolOnlyFold:
              item.mergedMessageIds.length > 1 ||
              (item.pieceId.contains(
                    '${ChatTimelinePieceId.separator}fold_tool_',
                  ) &&
                  _isToolOnly(original)),
          kind: _DeletableEntryKind.chunk,
        ),
      );
    } else if (item is ChatRunStatusItem) {
      final message = item.message;
      if (!item.standalone ||
          message.status == 'sending' ||
          message.id.startsWith(voiceCallLiveMessagePrefix) ||
          stagedMessageIds.contains(message.id)) {
        continue;
      }
      entries.add(
        _DeletableListEntry(
          selectionId: message.id,
          parentMessageId: message.id,
          originalSourceMessageId: message.sourceMessageId,
          mergedMessageIds: <String>[message.id],
          rawMessageIds: <String>{
            ChatTimelinePieceId.rawMessageIdOf(
              message.id,
              explicitSourceId: message.sourceMessageId,
            ),
          },
          isPrimaryBody: false,
          isToolOnlyFold: false,
          kind: _DeletableEntryKind.standaloneRunStatus,
        ),
      );
    }
  }

  bool isEntrySelected(_DeletableListEntry entry) =>
      remainingTargets.contains(entry.selectionId) ||
      remainingTargets.contains(entry.parentMessageId);

  final matchedTargetIds = <String>{};
  final affectedRawIds = <String>{};
  for (final entry in entries) {
    if (remainingTargets.contains(entry.selectionId)) {
      matchedTargetIds.add(entry.selectionId);
      affectedRawIds.addAll(entry.rawMessageIds);
    }
    if (remainingTargets.contains(entry.parentMessageId)) {
      matchedTargetIds.add(entry.parentMessageId);
      affectedRawIds.addAll(entry.rawMessageIds);
    }
  }
  final unmatchedTargets = <String>[
    for (final target in remainingTargets)
      if (!matchedTargetIds.contains(target)) target,
  ];
  for (final target in unmatchedTargets) {
    affectedRawIds.add(rawIdOfId(target));
  }

  final upgradedRawIds = <String>{};
  for (final rawId in affectedRawIds) {
    final rawEntries = [
      for (final entry in entries)
        if (entry.rawMessageIds.contains(rawId)) entry,
    ];
    final primaryEntries = [
      for (final entry in rawEntries)
        if (entry.isPrimaryBody) entry,
    ];
    if (primaryEntries.isNotEmpty) {
      if (primaryEntries.every(isEntrySelected)) {
        upgradedRawIds.add(rawId);
      }
    } else if (rawEntries.isNotEmpty &&
        rawEntries.every(isEntrySelected) &&
        rawEntries.any(
          (entry) => entry.kind == _DeletableEntryKind.standaloneRunStatus,
        )) {
      upgradedRawIds.add(rawId);
    }
  }

  final projectedIdsToHide = <String>{};
  final pieceIdsToHide = <String>{};
  for (final entry in entries) {
    if (!isEntrySelected(entry)) continue;
    if (entry.kind == _DeletableEntryKind.chunk && entry.isToolOnlyFold) {
      for (final mid in entry.mergedMessageIds) {
        final midRaw = rawIdOfId(
          mid,
          fallbackSourceId: mid == entry.parentMessageId
              ? entry.originalSourceMessageId
              : null,
        );
        if (!upgradedRawIds.contains(midRaw)) {
          projectedIdsToHide.add(mid);
        }
      }
      continue;
    }
    if (entry.rawMessageIds.every(upgradedRawIds.contains)) continue;
    if (entry.kind == _DeletableEntryKind.chunk) {
      pieceIdsToHide.add(entry.selectionId);
    } else {
      projectedIdsToHide.add(entry.selectionId);
    }
  }
  for (final target in unmatchedTargets) {
    final rawId = rawIdOfId(target);
    if (upgradedRawIds.contains(rawId)) continue;
    if (ChatTimelinePieceId.isPieceId(target)) {
      pieceIdsToHide.add(target);
    } else {
      projectedIdsToHide.add(target);
    }
  }

  return ChatTimelineDeletePlan(
    stagedMessageIds: resolvedStagedIds,
    rawMessageIdsToDelete: upgradedRawIds.toList(),
    projectedMessageIdsToHide: projectedIdsToHide.toList(),
    pieceIdsToHide: pieceIdsToHide.toList(),
  );
}

Message? _itemMessage(ChatMessageListItem item) => switch (item) {
  ChatMessageItem(:final message) => message,
  ChatChunkedMessageItem(:final originalMessage) => originalMessage,
  ChatRunStatusItem(:final message) => message,
  _ => null,
};

/// Appends a [ChatReplyActionsItem] after the last item of every assistant
/// turn, i.e. right before the next user message or the end.
List<ChatMessageListItem> _withReplyActions(List<ChatMessageListItem> items) {
  final result = <ChatMessageListItem>[];
  final turn = <Message>[];
  final turnMessageIds = <String>{};
  var insertAt = 0;
  void flush() {
    if (turn.isNotEmpty) {
      result.insert(
        insertAt,
        ChatReplyActionsItem(
          turn.last,
          messageIds: turnMessageIds.toList(),
          copyText: [
            for (final m in turn)
              if (_resolveChunkSourceText(m).trim() case final text
                  when text.isNotEmpty)
                text,
          ].join('\n\n'),
          finished: turn.every((m) => m.status != 'sending'),
        ),
      );
    }
    turn.clear();
    turnMessageIds.clear();
  }

  for (final item in items) {
    final message = _itemMessage(item);
    if (message != null && message.role == 'user') flush();
    result.add(item);
    final assistantItem = message != null
        ? message.role == 'assistant'
        : item is ChatTaskRunningItem;
    if (!assistantItem) continue;
    if (message != null && !turn.any((m) => m.id == message.id)) {
      turn.add(message);
    }
    if (message != null) {
      turnMessageIds.add(message.id);
    }
    if (item is ChatChunkedMessageItem) {
      turnMessageIds.addAll(item.mergedMessageIds);
    }
    insertAt = result.length;
  }
  flush();
  return result;
}

bool _isTaskReceipt(Message message) =>
    message.blocks?.any((block) => block is TaskReceiptBlock) ?? false;

Iterable<String> _delegateTaskIds(Message message) sync* {
  if (message.role != 'assistant') return;
  for (final block in message.blocks ?? const <MessageBlock>[]) {
    if (block is ToolBlock) {
      final taskId = delegateTaskIdOf(block);
      if (taskId != null) yield taskId;
    }
  }
}

List<ImagePreviewItem> collectChatMessageListImages(List<Message> messages) {
  final result = <ImagePreviewItem>[];
  for (final message in messages) {
    final blocks = message.blocks;
    if (blocks == null) continue;
    for (final block in blocks) {
      final isSticker = block is EmojiBlock;
      final heroTag = isSticker ? 'sticker_${block.id}' : 'image_${block.id}';
      final mediaId = _chatMessageListImageMediaId(block);
      if (mediaId != null) {
        result.add(ImagePreviewItem.media(mediaId: mediaId, heroTag: heroTag));
        continue;
      }
      final provider = resolveChatMessageListImageProvider(block);
      if (provider == null) continue;
      result.add(ImagePreviewItem(provider: provider, heroTag: heroTag));
    }
  }
  return result;
}

/// 存在共享媒体库里的图片／表情包，由预览页按媒体解析本机文件。
String? _chatMessageListImageMediaId(MessageBlock block) {
  if (block is ImageBlock) return block.mediaId;
  if (block is EmojiBlock) {
    return mediaIdFromReference(
      StickerLibrary.resolveLocalPath(
        block.path.trim(),
        stickerId: block.emojiId,
      ).replaceAll('\\', '/'),
    );
  }
  return null;
}

ImageProvider? resolveChatMessageListImageProvider(MessageBlock block) {
  if (block is EmojiBlock) {
    final rawPath = StickerLibrary.resolveLocalPath(
      block.path.trim(),
      stickerId: block.emojiId,
    );
    final path = rawPath.replaceAll('\\', '/');
    if (path.isEmpty || mediaIdFromReference(path) != null) return null;
    final isNetwork = path.startsWith('http://') || path.startsWith('https://');
    final isAsset = path.startsWith('assets/') || path.startsWith('packages/');
    if (isNetwork) return CachedNetworkImageProvider(path);
    if (isAsset) return AssetImage(path);
    final localPath = rawPath.startsWith('file://')
        ? Uri.parse(rawPath).toFilePath()
        : rawPath;
    return FileImage(File(localPath));
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
  'user',
  'char',
  'system',
  'assistant',
  'human',
  'model',
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
  final wrapper = allowUnwrap
      ? soleUnknownBodyWrapper(text, tagPresentation)
      : null;
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

/// 思维链折叠段：预设思考类标签统一标题「思考」，模型原生思考为「模型思考」，
/// 没有标题时显示「思考过程」。
bool _isThinkingFoldTitle(String title) {
  final trimmed = title.trim();
  return trimmed.isEmpty ||
      trimmed == '思考' ||
      trimmed == '思考过程' ||
      trimmed == ChatMessageProcessor.modelThinkingTitle;
}

/// 消息里存着的思考块（模型原生思考）投影成折叠段。
List<TagFoldPart> _modelThinkingFolds(Message message) {
  final blocks = message.blocks;
  if (blocks == null) return const <TagFoldPart>[];
  return [
    for (final block in blocks)
      if (block is ThinkingBlock && block.content.trim().isNotEmpty)
        TagFoldPart(
          title: block.title?.trim().isNotEmpty == true
              ? block.title!
              : ChatMessageProcessor.modelThinkingTitle,
          content: block.content,
          closed: block.status != BlockStatus.streaming,
        ),
  ];
}

const int _kToolFoldResultMaxChars = 2000;

const _kCodemodeCallStatusLabels = {
  'running': '进行中',
  'ok': '完成',
  'error': '失败',
  'cancelled': '已取消',
};

/// The calls a codemode script made, one line each, as the backend records
/// them in `result['codemodeCalls']`.
void _writeCodemodeCalls(StringBuffer buffer, Object? calls) {
  if (calls is! List || calls.isEmpty) return;
  buffer.writeln('脚本里调用了 ${calls.length} 个工具');
  for (final call in calls.whereType<Map>()) {
    final status =
        _kCodemodeCallStatusLabels[call['status']] ?? '${call['status']}';
    final duration = call['durationMs'];
    final error = call['error'];
    final seconds = duration is! num
        ? ''
        : duration < 1000
        ? ' · ${duration.round()} 毫秒'
        : ' · ${(duration / 1000).toStringAsFixed(1)} 秒';
    final reason = error is String && error.isNotEmpty ? '：$error' : '';
    final hint = toolCallHint(_decodeCodemodeArgs(call['args']));
    final what = hint == null ? '' : ' ${hint.replaceAll('`', "'")}';
    buffer.writeln('- `${call['name']}$what` $status$seconds$reason');
  }
}

bool _isToolOnly(Message message) {
  final blocks = message.blocks;
  return blocks != null &&
      blocks.isNotEmpty &&
      blocks.every((block) => block is ToolBlock);
}

/// 一条消息里的工具调用块投影成一个折叠段，多次调用逐个列在里面；
/// 应用自己补的内部上下文块不算工具调用。
List<TagFoldPart> _toolCallFolds(Message message) {
  final calls = [
    for (final block in message.blocks ?? const <MessageBlock>[])
      if (block is ToolBlock &&
          block.toolName !=
              ChatRequestMessageBuilder.internalImageContextToolName)
        block,
  ];
  if (calls.isEmpty) return const <TagFoldPart>[];
  if (calls.length == 1) {
    return [
      TagFoldPart(
        title: _toolFoldTitle(calls),
        content: _formatToolFoldContent(calls.single),
        closed: true,
      ),
    ];
  }
  return [
    TagFoldPart(
      title: _toolFoldTitle(calls),
      content: [
        for (final (index, call) in calls.indexed)
          '**${index + 1}. ${call.toolName == 'codemode' ? '脚本' : _toolUseLabel(_toolUses(call).single)}**\n\n${_formatToolFoldContent(call)}',
      ].join('\n\n---\n\n'),
      closed: true,
    ),
  ];
}

typedef _ToolUse = ({
  String name,
  Map<String, dynamic>? arguments,
  bool failed,
});

/// The tools a call actually used: a codemode script stands for the tools it
/// called, any other call for itself.
List<_ToolUse> _toolUses(ToolBlock block) {
  if (block.toolName != 'codemode') {
    return [(name: block.toolName, arguments: block.arguments, failed: false)];
  }
  final nested = block.result?['codemodeCalls'];
  if (nested is! List) return const [];
  return [
    for (final call in nested.whereType<Map>())
      (
        name: '${call['name']}',
        arguments: _decodeCodemodeArgs(call['args']),
        failed: call['status'] == 'error',
      ),
  ];
}

Map<String, dynamic>? _decodeCodemodeArgs(Object? args) {
  if (args is! String) return null;
  try {
    final decoded = jsonDecode(args);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    // The backend cuts args at 200 chars; pull the leading string fields out.
    final fields = RegExp(r'"(\w+)":"((?:[^"\\]|\\.)*)').allMatches(args);
    return {for (final m in fields) m[1]!: m[2]!};
  }
}

String _toolUseLabel(_ToolUse use) {
  final hint = toolCallHint(use.arguments);
  return hint == null ? use.name : '${use.name} · $hint';
}

/// One call shows its tool and key argument; several list the distinct tools
/// and how many calls ran. Failed nested calls are counted at the end.
String _toolFoldTitle(List<ToolBlock> calls) {
  final uses = [for (final call in calls) ..._toolUses(call)];
  if (uses.isEmpty) return '运行脚本';
  final failed = uses.where((use) => use.failed).length;
  final suffix = failed == 0 ? '' : ' · $failed 个失败';
  if (uses.length == 1) return '${_toolUseLabel(uses.single)}$suffix';
  final names = {for (final use in uses) use.name}.join('、');
  return '$names · ${uses.length} 次$suffix';
}

String _formatToolFoldContent(ToolBlock block) {
  final buffer = StringBuffer();
  final arguments = block.arguments;
  final script = block.toolName == 'codemode' ? (arguments?['code']) : null;
  if (script is String) {
    buffer
      ..writeln('脚本')
      ..writeln('```js')
      ..writeln(script.trimRight())
      ..writeln('```');
    _writeCodemodeCalls(buffer, block.result?['codemodeCalls']);
  } else if (arguments != null && arguments.isNotEmpty) {
    buffer
      ..writeln('参数')
      ..writeln('```json')
      ..writeln(const JsonEncoder.withIndent('  ').convert(arguments))
      ..writeln('```');
  }
  final rawResult = block.result?['content'] ?? block.result;
  if (rawResult != null) {
    var text = rawResult is String
        ? rawResult
        : const JsonEncoder.withIndent('  ').convert(rawResult);
    if (text.length > _kToolFoldResultMaxChars) {
      text = '${text.substring(0, _kToolFoldResultMaxChars)}\n…';
    }
    buffer
      ..writeln('结果')
      ..writeln('```')
      ..writeln(text)
      ..writeln('```');
  }
  return buffer.toString().trimRight();
}

/// 消息里有文字以外的可见块（语音、图片、文件等）时整条显示，不分段也不投影。
/// 工具块不显示（如生图完成后补在锚点文字消息上的图片上下文），思考块投影成
/// 折叠段，都不能挡住标签投影，否则预设正文标签会原样露出。
bool _hasNonTextBlocks(Message message) {
  final blocks = message.blocks;
  return blocks?.any(
        (block) =>
            block is! TextBlock &&
            block is! ToolBlock &&
            block is! ThinkingBlock,
      ) ??
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
