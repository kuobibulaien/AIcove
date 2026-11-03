import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../content_tags/domain/content_tag_spec.dart';
import '../../content_tags/domain/tag_presentation.dart';

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
const _foldOwnerId = 'dialogue_options_fold';

final ContentTagScanner _optionScanner = ContentTagScanner(
  ContentTagRegistry(const [
    StaticContentTagProvider(
      providerId: _ownerId,
      tagSpecs: [ContentTagSpec(name: 'option', ownerId: _ownerId)],
    ),
  ]),
);

final RegExp _listMarker = RegExp(
  r'^\s*(?:[-*•·]|\d{1,2}[.、)）:：]|[A-Za-z][.、)）:：]|[（(]\d{1,2}[)）])\s*',
);
final RegExp _extraBlankLines = RegExp(r'\n{3,}');

bool _mayContainOptions(String text, Set<String> tags) {
  final lower = text.toLowerCase();
  return tags.any(
    (name) => lower.contains('<$name') || lower.contains('</$name'),
  );
}

/// 默认只认 `<options>`；预设标签映射里归为“选项”的标签（如 `<branches>`）
/// 由调用方传入（ADR0046）。
const Set<String> defaultDialogueOptionTags = {'options'};

/// 常见的思考／折叠标签：写在它们里面的选项标签只是被提到，不是选项。
const Set<String> _builtinFoldTags = {
  'think',
  'thinking',
  'thought',
  'cot',
  'reasoning',
  '思考',
  '思维链',
  'details',
  'comic_plan',
  'think_nya',
  'think_nya~',
  'report_nya',
  'report_nya~',
};

final Map<String, ContentTagScanner> _optionTagScanners = {};

/// 选项标签先注册：同名时选项优先于折叠。
ContentTagScanner _scannerForTags(Set<String> tags, Set<String> foldTags) {
  final key =
      '${(tags.toList()..sort()).join(',')}|${(foldTags.toList()..sort()).join(',')}';
  return _optionTagScanners[key] ??= ContentTagScanner(
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
      StaticContentTagProvider(
        providerId: _foldOwnerId,
        tagSpecs: [
          for (final name in {..._builtinFoldTags, ...foldTags})
            ContentTagSpec(
              name: name,
              ownerId: _foldOwnerId,
              wrapsRestWhenUnclosed: true,
            ),
        ],
      ),
    ]),
  );
}

/// 解析一段回复文本中最后一组对话选项；没有时返回空列表。
/// 只认顶层且完整闭合的选项标签。
List<String> parseDialogueOptions(
  String text, {
  Set<String> tags = defaultDialogueOptionTags,
  Set<String> foldTags = const {},
}) {
  final lower = text.toLowerCase();
  if (!tags.any((name) => lower.contains('<$name'))) return const [];
  ContentTagElement? last;
  for (final segment in _scannerForTags(tags, foldTags).scan(maskCode(text))) {
    if (segment is ContentTagElement &&
        segment.spec.ownerId == _ownerId &&
        segment.closed &&
        segment.inner.trim().isNotEmpty) {
      last = segment;
    }
  }
  if (last == null) return const [];
  final inner = last.inner;
  final segments = _optionScanner.scan(inner);
  // 写了 <option> 就只认闭合的那些，残缺的不退回按行拆分。
  final raw = segments.any((segment) => segment is! ContentTagText)
      ? [
          for (final segment in segments.whereType<ContentTagElement>())
            if (segment.closed) segment.inner,
        ]
      : inner.split('\n');
  final seen = <String>{};
  return [
    for (final item in raw)
      if (unmaskCode(item.replaceFirst(_listMarker, '').trim()) case final value
          when value.isNotEmpty && seen.add(value))
        value,
  ];
}

/// 显示副本：去掉顶层 `<options>` 元素及孤立闭标签。[allowUnclosedTail] 为
/// true 时连流式截断未闭合的一并去掉，为 false 时未闭合的原样保留。
String stripDialogueOptions(
  String text, {
  bool allowUnclosedTail = true,
  Set<String> tags = defaultDialogueOptionTags,
  Set<String> foldTags = const {},
}) {
  if (!_mayContainOptions(text, tags)) return text;
  final output = StringBuffer();
  var removed = false;
  for (final segment in _scannerForTags(tags, foldTags).scan(maskCode(text))) {
    final isOptionTag = switch (segment) {
      ContentTagElement(:final spec) ||
      ContentTagOrphanClose(:final spec) => spec.ownerId == _ownerId,
      ContentTagText() => false,
    };
    final keepUnclosed =
        !allowUnclosedTail && segment is ContentTagElement && !segment.closed;
    if (isOptionTag && !keepUnclosed) {
      removed = true;
    } else {
      output.write(text.substring(segment.start, segment.end));
    }
  }
  if (!removed) return text;
  return output.toString().replaceAll(_extraBlankLines, '\n\n').trim();
}

/// 聊天列表显示用的消息副本；无选项标签时原样返回同一实例。
Message stripDialogueOptionsForDisplay(
  Message message, {
  TagPresentationMap tagPresentation = const {},
}) {
  if (message.role != 'assistant') return message;
  final tags = {
    ...defaultDialogueOptionTags,
    for (final entry in tagPresentation.entries)
      if (entry.value.presentation == TagPresentation.options) entry.key,
  };
  final foldTags = {
    for (final entry in tagPresentation.entries)
      if (entry.value.presentation == TagPresentation.fold) entry.key,
  };
  String strip(String text) => stripDialogueOptions(
    text,
    allowUnclosedTail: message.status == 'sending',
    tags: tags,
    foldTags: foldTags,
  );
  final blocks = message.blocks;
  if (blocks == null || blocks.isEmpty) {
    if (!_mayContainOptions(message.content, tags)) return message;
    return message.copyWith(content: strip(message.content));
  }
  if (!blocks.any((block) => _hasOptionsText(block, tags))) return message;
  return message.copyWith(
    blocks: [
      for (final block in blocks)
        _hasOptionsText(block, tags)
            ? (block as TextBlock).copyWith(content: strip(block.content))
            : block,
    ],
  );
}

bool _hasOptionsText(MessageBlock block, Set<String> tags) =>
    block is TextBlock &&
    block is! ChatRecordBlock &&
    _mayContainOptions(block.content, tags);

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
  Set<String> foldTags = const {},
}) {
  for (final message in messages.reversed) {
    if (message.role != 'assistant' || message.status == 'sending') {
      return null;
    }
    final items = parseDialogueOptions(
      _messageText(message),
      tags: tags,
      foldTags: foldTags,
    );
    if (items.isNotEmpty) {
      return DialogueOptions(messageId: message.id, items: items);
    }
  }
  return null;
}
