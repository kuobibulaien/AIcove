import '../../../../features/conversation_state/domain/mvu_content.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/content_tags/domain/tag_presentation.dart';
import '../../../../features/dialogue_options/domain/dialogue_options.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/services/chat_message_processor.dart';
import '../../../../features/chat/services/chat_request_message_builder.dart';
import '../../../../features/task_agent/application/delegate_task_plugin.dart';
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
  const ChatRunStatusItem(this.status, {required this.associatedMessageId});

  final ChatRunStatus status;
  final String associatedMessageId;
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
  if (item is ChatChunkedMessageItem) return chatChunkDisplayMessage(item);
  return null;
}

/// The message a chunk bubble renders; fold chunks carry a thinking block so
/// the bubble draws the fold component (ADR0046).
Message chatChunkDisplayMessage(ChatChunkedMessageItem item) {
  final message = item.originalMessage;
  final chunkId = '${message.id}_chunk_${item.chunkIndex}';
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
  );
}

List<ChatMessageListItem> buildChatMessageListItems({
  required List<Message> messages,
  MessageFormatConfig? config,
  TagPresentationMap tagPresentation = const {},
  bool showTimeDividers = true,
  bool showThinkingFolds = true,
  bool showToolCallFolds = false,
  bool showReplyActions = false,
}) {
  final items = <ChatMessageListItem>[];
  final enableChunking = config?.enableChunking ?? true;

  Message? previousShown;
  for (var index = 0; index < messages.length; index++) {
    // 后台任务回执只给人设转告用，聊天里不显示（ADR0088 §4）。
    if (_isTaskReceipt(messages[index])) continue;
    final start = index;
    var source = messages[index];
    // 连着几轮只调工具不说话时，相邻的工具调用收拢成一个过程折叠段。
    if (showToolCallFolds && _isToolOnly(source)) {
      final blocks = [...source.blocks!];
      while (index + 1 < messages.length && _isToolOnly(messages[index + 1])) {
        index++;
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
    );
    final runStatus = ChatRunStatus.of(currentMessage);
    final runningItems = [
      for (final taskId in _delegateTaskIds(currentMessage))
        ChatTaskRunningItem(taskId, associatedMessageId: currentMessage.id),
      if (runStatus != null)
        ChatRunStatusItem(runStatus, associatedMessageId: currentMessage.id),
    ];
    // 只有派活调用或运行状态的那一轮不画空气泡，只留等待条／状态行。
    if (runningItems.isNotEmpty &&
        currentMessage.status != 'sending' &&
        _resolveChunkSourceText(currentMessage).trim().isEmpty &&
        !_hasNonTextBlocks(currentMessage)) {
      items.addAll(runningItems);
      continue;
    }
    // 只有选项的回复段交给对话选项气泡展示，不留空气泡。
    if (!identical(currentMessage, source) &&
        currentMessage.status != 'sending' &&
        _resolveChunkSourceText(currentMessage).trim().isEmpty &&
        !_hasNonTextBlocks(currentMessage)) {
      continue;
    }
    // 时间小气泡属于时间感知插件：插件关掉时不显示，但隔了很久的消息照样重新露头像。
    final hasTimeDivider = start == 0 ||
        currentMessage.createdAt
                .difference(messages[start - 1].createdAt)
                .inMinutes >=
            20;
    if (hasTimeDivider && showTimeDividers) {
      items.add(
        ChatTimeDividerItem(
          currentMessage.createdAt,
          associatedMessageId: currentMessage.id,
        ),
      );
    }

    final showAvatar = hasTimeDivider ||
        previousShown == null ||
        previousShown.role != currentMessage.role;
    previousShown = currentMessage;

    final chunkSourceText = _resolveChunkSourceText(currentMessage);
    final shouldChunk = enableChunking &&
        currentMessage.role == 'assistant' &&
        currentMessage.status != 'sending' &&
        !_hasNonTextBlocks(currentMessage) &&
        chunkSourceText.trim().isNotEmpty;

    // 预设语义标签：折叠标签单独成折叠气泡，正文标签去壳，其余照常分段。
    final projectable = currentMessage.role == 'assistant' &&
        !_hasNonTextBlocks(currentMessage);
    var tagParts = projectable
        ? _projectTagParts(
            chunkSourceText,
            tagPresentation,
            // 生成中只用发送前定好的映射，不临时判断未知外壳。
            allowUnwrap: currentMessage.status != 'sending',
          )
        : null;
    // 过程排在正文前：模型原生思考 → 工具调用 → 正文里的标签思维链。
    final processFolds = projectable
        ? [
            ..._modelThinkingFolds(currentMessage),
            if (showToolCallFolds) ..._toolCallFolds(currentMessage),
          ]
        : const <TagFoldPart>[];
    if (processFolds.isNotEmpty) {
      tagParts = [
        ...processFolds,
        ...tagParts ??
            [
              if (chunkSourceText.trim().isNotEmpty)
                TagBodyPart(chunkSourceText),
            ],
      ];
    }
    if (tagParts != null && !showThinkingFolds) {
      tagParts = [
        for (final part in tagParts)
          if (part is! TagFoldPart || !_isThinkingFoldTitle(part.title)) part,
      ];
    }
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
      items.addAll(runningItems);
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
        items.addAll(runningItems);
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
    items.addAll(runningItems);
  }

  return showReplyActions ? _withReplyActions(items) : items;
}

Message? _itemMessage(ChatMessageListItem item) => switch (item) {
      ChatMessageItem(:final message) => message,
      ChatChunkedMessageItem(:final originalMessage) => originalMessage,
      _ => null,
    };

/// Appends a [ChatReplyActionsItem] after the last item of every assistant
/// turn, i.e. right before the next user message or the end.
List<ChatMessageListItem> _withReplyActions(List<ChatMessageListItem> items) {
  final result = <ChatMessageListItem>[];
  final turn = <Message>[];
  var insertAt = 0;
  void flush() {
    if (turn.isNotEmpty) {
      result.insert(
        insertAt,
        ChatReplyActionsItem(
          turn.last,
          messageIds: [for (final m in turn) m.id],
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
  }

  for (final item in items) {
    final message = _itemMessage(item);
    if (message != null && message.role == 'user') flush();
    result.add(item);
    final assistantItem = message != null
        ? message.role == 'assistant'
        : item is ChatTaskRunningItem || item is ChatRunStatusItem;
    if (!assistantItem) continue;
    if (message != null && (turn.isEmpty || turn.last.id != message.id)) {
      turn.add(message);
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
    final status = _kCodemodeCallStatusLabels[call['status']] ?? '${call['status']}';
    final duration = call['durationMs'];
    final error = call['error'];
    final seconds = duration is! num
        ? ''
        : duration < 1000
        ? ' · ${duration.round()} 毫秒'
        : ' · ${(duration / 1000).toStringAsFixed(1)} 秒';
    final reason = error is String && error.isNotEmpty ? '：$error' : '';
    final hint = _toolHint(_decodeCodemodeArgs(call['args']));
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

typedef _ToolUse = ({String name, Map<String, dynamic>? arguments, bool failed});

const int _kToolHintMaxChars = 40;

/// Argument keys worth showing next to a tool name, most telling first.
const _kToolHintKeys = [
  'command',
  'path',
  'url',
  'query',
  'pattern',
  'name',
  'prompt',
];

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

/// The first line of the most telling argument, cut to a title-friendly length.
String? _toolHint(Map<String, dynamic>? arguments) {
  for (final key in _kToolHintKeys) {
    final value = arguments?[key];
    if (value is! String || value.trim().isEmpty) continue;
    final chars = value.trim().split('\n').first.characters;
    return chars.length > _kToolHintMaxChars
        ? '${chars.take(_kToolHintMaxChars)}…'
        : chars.toString();
  }
  return null;
}

String _toolUseLabel(_ToolUse use) {
  final hint = _toolHint(use.arguments);
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
            block is! TextBlock && block is! ToolBlock && block is! ThinkingBlock,
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
