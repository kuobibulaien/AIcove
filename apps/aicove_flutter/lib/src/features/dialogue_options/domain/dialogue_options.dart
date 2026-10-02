import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../content_tags/domain/content_tag_spec.dart';

/// 对话选项（ADR0045）：预设让模型在回复末尾输出
/// `<options><option>…</option></options>`，界面把它从气泡里取出，
/// 改由右下角选项气泡展示。raw 原文不改，这里只产出显示派生。
class DialogueOptions {
  const DialogueOptions({required this.messageId, required this.items});

  final String messageId;
  final List<String> items;

  /// 同一条回复的同一组选项只提示一次；选用后以此标记为已处理。
  String get signature => '$messageId:${Object.hashAll(items)}';
}

const _ownerId = 'dialogue_options';

final ContentTagScanner _optionsScanner = ContentTagScanner(
  ContentTagRegistry(const [
    StaticContentTagProvider(
      providerId: _ownerId,
      tagSpecs: [
        ContentTagSpec(
          name: 'options',
          ownerId: _ownerId,
          display: ContentTagDisplay.hidden,
        ),
      ],
    ),
  ]),
);

final ContentTagScanner _optionScanner = ContentTagScanner(
  ContentTagRegistry(const [
    StaticContentTagProvider(
      providerId: _ownerId,
      tagSpecs: [ContentTagSpec(name: 'option', ownerId: _ownerId)],
    ),
  ]),
);

final RegExp _optionsHint = RegExp('</?options', caseSensitive: false);
final RegExp _listMarker = RegExp(
  r'^\s*(?:[-*•·]|\d{1,2}[.、)）:：]|[A-Za-z][.、)）:：]|[（(]\d{1,2}[)）])\s*',
);
final RegExp _extraBlankLines = RegExp(r'\n{3,}');

bool _mayContainOptions(String text) => _optionsHint.hasMatch(text);

/// 默认只认 `<options>`；预设标签映射里归为“选项”的标签（如 `<branches>`）
/// 由调用方传入（ADR0046）。
const Set<String> defaultDialogueOptionTags = {'options'};

final Map<String, ContentTagScanner> _customOptionScanners = {};

ContentTagScanner _scannerForTags(Set<String> tags) {
  if (tags.length == 1 && tags.first == 'options') return _optionsScanner;
  final key = (tags.toList()..sort()).join(',');
  return _customOptionScanners[key] ??= ContentTagScanner(
    ContentTagRegistry([
      StaticContentTagProvider(
        providerId: _ownerId,
        tagSpecs: [
          for (final name in tags)
            ContentTagSpec(
              name: name,
              ownerId: _ownerId,
              display: ContentTagDisplay.hidden,
            ),
        ],
      ),
    ]),
  );
}

/// 解析一段回复文本中最后一组对话选项；没有时返回空列表。
List<String> parseDialogueOptions(
  String text, {
  Set<String> tags = defaultDialogueOptionTags,
}) {
  final lower = text.toLowerCase();
  if (!tags.any((name) => lower.contains('<$name'))) return const [];
  ContentTagElement? last;
  for (final segment in _scannerForTags(tags).scan(text)) {
    if (segment is ContentTagElement && segment.inner.trim().isNotEmpty) {
      last = segment;
    }
  }
  if (last == null) return const [];
  final inner = last.inner;
  final tagged = _optionScanner
      .scan(inner)
      .whereType<ContentTagElement>()
      .map((e) => e.inner)
      .toList();
  final raw = tagged.isNotEmpty ? tagged : inner.split('\n');
  final seen = <String>{};
  return [
    for (final item in raw)
      if (item.replaceFirst(_listMarker, '').trim() case final value
          when value.isNotEmpty && seen.add(value))
        value,
  ];
}

/// 显示副本：去掉全部 `<options>` 元素（含流式截断未闭合的）及孤立闭标签。
String stripDialogueOptions(String text) {
  if (!_mayContainOptions(text)) return text;
  final output = StringBuffer();
  for (final segment in _optionsScanner.scan(text)) {
    if (segment is ContentTagText) output.write(segment.text);
  }
  return output.toString().replaceAll(_extraBlankLines, '\n\n').trim();
}

/// 聊天列表显示用的消息副本；无选项标签时原样返回同一实例。
Message stripDialogueOptionsForDisplay(Message message) {
  if (message.role != 'assistant') return message;
  final blocks = message.blocks;
  if (blocks == null || blocks.isEmpty) {
    if (!_mayContainOptions(message.content)) return message;
    return message.copyWith(content: stripDialogueOptions(message.content));
  }
  if (!blocks.any(_hasOptionsText)) return message;
  return message.copyWith(
    blocks: [
      for (final block in blocks)
        _hasOptionsText(block)
            ? (block as TextBlock).copyWith(
                content: stripDialogueOptions(block.content),
              )
            : block,
    ],
  );
}

bool _hasOptionsText(MessageBlock block) =>
    block is TextBlock &&
    block is! ChatRecordBlock &&
    _mayContainOptions(block.content);

String _messageText(Message message) {
  final blocks = message.blocks;
  if (blocks == null || blocks.isEmpty) return message.content;
  return blocks.whereType<TextBlock>().map((b) => b.content).join('\n\n');
}

/// 取会话末尾那一轮助手回复里的最后一组选项。一轮回复可能被拆成
/// 文字、语音、图片等多条消息，所以从末尾向前看完整个连续的助手段。
DialogueOptions? latestDialogueOptions(
  List<Message> messages, {
  Set<String> tags = defaultDialogueOptionTags,
}) {
  for (final message in messages.reversed) {
    if (message.role != 'assistant' || message.status == 'sending') {
      return null;
    }
    final items = parseDialogueOptions(_messageText(message), tags: tags);
    if (items.isNotEmpty) {
      return DialogueOptions(messageId: message.id, items: items);
    }
  }
  return null;
}
