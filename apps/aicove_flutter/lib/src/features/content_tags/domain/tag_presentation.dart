import '../../../core/utils/markdown_fence.dart';
import '../../../core/utils/message_formatter.dart';
import 'content_tag_registry.dart';
import 'content_tag_scanner.dart';
import 'content_tag_spec.dart';

/// 语义标签在聊天界面上的呈现（ADR0046）：只有正文、折叠、选项三种。
/// “隐藏”由后端的显示正则负责，不是界面概念。
enum TagPresentation { body, fold, options }

class TagPresentationEntry {
  const TagPresentationEntry(this.presentation, this.title);

  final TagPresentation presentation;

  /// 折叠气泡标题。
  final String title;

  Map<String, dynamic> toJson() => {
        'display': presentation.name,
        'title': title,
      };

  static TagPresentationEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final presentation = TagPresentation.values
        .where((value) => value.name == json['display'])
        .firstOrNull;
    if (presentation == null) return null;
    return TagPresentationEntry(presentation, (json['title'] ?? '').toString());
  }
}

/// 标签名（小写）→ 呈现方式。写入助手 rawPayload 作为显示快照。
typedef TagPresentationMap = Map<String, TagPresentationEntry>;

Map<String, dynamic> tagPresentationMapToJson(TagPresentationMap map) => {
      for (final entry in map.entries) entry.key: entry.value.toJson(),
    };

TagPresentationMap tagPresentationMapFromJson(Object? json) {
  if (json is! Map) return const {};
  final result = <String, TagPresentationEntry>{};
  for (final entry in json.entries) {
    final value = TagPresentationEntry.fromJson(entry.value);
    if (value != null) result[entry.key.toString().toLowerCase()] = value;
  }
  return result;
}

/// 投影后的显示片段。
sealed class TagDisplayPart {
  const TagDisplayPart();
}

class TagBodyPart extends TagDisplayPart {
  const TagBodyPart(this.text);
  final String text;
}

class TagFoldPart extends TagDisplayPart {
  const TagFoldPart({
    required this.title,
    required this.content,
    required this.closed,
  });

  final String title;
  final String content;

  /// false 表示流式中尚未写完。
  final bool closed;
}

// 属性值可以含 `>`，与扫描器同样按引号识别标签边界。
const String _tagBody = '(?:"[^"]*"|\'[^\']*\'|[^\'">])*';
final RegExp _summaryElement = RegExp(
  '<summary(?=[\\s>])$_tagBody>([\\s\\S]*?)</summary\\s*>',
  caseSensitive: false,
);
final RegExp _markup = RegExp('</?[A-Za-z][^\\s/>]*$_tagBody>');
final RegExp _blankLines = RegExp(r'\n{3,}');

final Map<String, ContentTagScanner> _scannerCache = {};

/// 只作页面结构的 HTML 名与插件自有标签：永远不当作预设语义标签（ADR0048）。
/// `summary`、`details` 是双用途名，不在此列。
const Set<String> htmlStructureTagNames = {
  'div', 'span', 'p', 'br', 'style', 'script', 'b', 'i', 'u', 'em', 'strong',
  'font', 'ruby', 'rt', 'html', 'head', 'body', 'meta', 'button', 'img', 'a',
  'pre', 'code', 'li', 'ul', 'ol', 'table', 'tr', 'td', 'th', 'h1', 'h2', 'h3',
  'h4', 'small', 'title', 'svg', 'path', 'blockquote', 'hr', 'sup', 'sub',
};

/// 代码块（围栏与行内反引号）里的 `<` 换成占位符，扫描时就不会把示例代码
/// 当成语义标签（ADR0048）。等长替换，区间偏移不变。
const String _codeMask = '\uE000';
final RegExp _inlineCode = RegExp(r'`[^`\n]+`');

String _maskCode(String text) {
  if (!text.contains('<') || (!text.contains('`') && !text.contains('~~~'))) {
    return text;
  }
  final chars = text.split('');
  void mask(int start, int end) {
    for (var i = start; i < end && i < chars.length; i++) {
      if (chars[i] == '<') chars[i] = _codeMask;
    }
  }

  final fences = scanFencedCodeBlocks(text);
  for (final block in fences) {
    mask(block.start, block.end);
  }
  for (final match in _inlineCode.allMatches(text)) {
    if (fences.any((b) => match.start >= b.start && match.start < b.end)) {
      continue;
    }
    mask(match.start, match.end);
  }
  return chars.join();
}

String _unmask(String text) =>
    text.contains(_codeMask) ? text.replaceAll(_codeMask, '<') : text;

ContentTagScanner _scannerFor(TagPresentationMap map) {
  final key = (map.keys.toList()..sort()).join('\u0000');
  return _scannerCache[key] ??= ContentTagScanner(
    ContentTagRegistry([
      StaticContentTagProvider(
        providerId: 'presentation',
        tagSpecs: [
          for (final name in map.keys)
            ContentTagSpec(name: name, ownerId: 'presentation'),
        ],
      ),
    ]),
  );
}

/// 自动分段的标签保护区（ADR0047）：折叠与选项标签整块不切；正文标签去壳后
/// 属于正文，只保护其中嵌套的组件。与 [projectTagPresentation] 同一套扫描规则，
/// 预填充场景（开头只有折叠闭标签）从文本开头保护到闭标签。
List<ProtectedTextRange> protectedTagRanges(
  String text,
  TagPresentationMap map, {
  int offset = 0,
}) {
  if (map.isEmpty || !text.contains('<')) return const [];
  final ranges = <ProtectedTextRange>[];
  var sawElement = false;
  for (final segment in _scannerFor(map).scan(_maskCode(text))) {
    switch (segment) {
      case ContentTagText():
        break;
      case ContentTagOrphanClose(:final spec):
        if (!sawElement &&
            map[spec.name]!.presentation == TagPresentation.fold) {
          ranges.add(ProtectedTextRange(offset, offset + segment.end));
        }
      case ContentTagElement():
        sawElement = true;
        if (map[segment.spec.name]!.presentation == TagPresentation.body) {
          ranges.addAll(protectedTagRanges(
            segment.inner,
            map,
            offset: offset + segment.start + segment.openTag.length,
          ));
        } else {
          ranges.add(ProtectedTextRange(
            offset + segment.start,
            offset + segment.end,
            closed: segment.closed,
          ));
        }
    }
  }
  return ranges;
}

/// 把一段助手文本按呈现映射切成正文与折叠片段（ADR0046）。
///
/// - 折叠标签 → 折叠片段；正文里的 HTML 标记剥成纯文本，`<summary>` 作标题。
/// - 正文标签 → 去壳，内部继续投影（正文里可以再有折叠）。
/// - 选项标签 → 丢弃（由对话选项气泡展示）。
/// - 预填充场景：文本开头没有开标签、只出现折叠标签的闭标签时，
///   闭标签之前的内容作为折叠片段。
List<TagDisplayPart> projectTagPresentation(
  String text,
  TagPresentationMap map,
) =>
    [
      for (final part in _project(_maskCode(text), map))
        switch (part) {
          TagBodyPart(:final text) => TagBodyPart(_unmask(text)),
          TagFoldPart() => TagFoldPart(
              title: _unmask(part.title),
              content: _unmask(part.content),
              closed: part.closed,
            ),
        },
    ];

List<TagDisplayPart> _project(String text, TagPresentationMap map) {
  if (map.isEmpty || !text.contains('<')) {
    return text.trim().isEmpty ? const [] : [TagBodyPart(text.trim())];
  }
  final parts = <TagDisplayPart>[];
  final body = StringBuffer();
  void flushBody() {
    final value = body.toString().replaceAll(_blankLines, '\n\n').trim();
    body.clear();
    if (value.isNotEmpty) parts.add(TagBodyPart(value));
  }

  for (final segment in _scannerFor(map).scan(text)) {
    switch (segment) {
      case ContentTagText(:final text):
        body.write(text);
      case ContentTagOrphanClose(:final spec, :final closeTag):
        final entry = map[spec.name]!;
        if (entry.presentation == TagPresentation.fold && parts.isEmpty) {
          final content = body.toString();
          body.clear();
          _addFold(parts, entry.title, content, map, closed: true);
        } else if (entry.presentation == TagPresentation.body) {
          continue;
        } else {
          body.write(closeTag);
        }
      case ContentTagElement():
        final entry = map[segment.spec.name]!;
        switch (entry.presentation) {
          case TagPresentation.options:
            break;
          case TagPresentation.body:
            flushBody();
            parts.addAll(_project(segment.inner, map));
          case TagPresentation.fold:
            flushBody();
            _addFold(
              parts,
              entry.title,
              segment.inner,
              map,
              closed: segment.closed,
            );
        }
    }
  }
  flushBody();
  return parts;
}

void _addFold(
  List<TagDisplayPart> parts,
  String defaultTitle,
  String inner,
  TagPresentationMap map, {
  required bool closed,
}) {
  var title = defaultTitle;
  var content = inner;
  final summary = _summaryElement.firstMatch(content);
  if (summary != null) {
    final summaryText = summary.group(1)!.replaceAll(_markup, '').trim();
    if (summaryText.isNotEmpty) title = summaryText;
    content = content.replaceRange(summary.start, summary.end, '');
  }
  // 折叠正文里的语义标签同样按映射处理（选项丢弃、嵌套折叠展平为文字）。
  content = _project(content, map)
      .map((part) => switch (part) {
            TagBodyPart(:final text) => text,
            TagFoldPart(:final title, :final content) => '$title\n$content',
          })
      .join('\n\n');
  content = content.replaceAll(_markup, '').replaceAll(_blankLines, '\n\n');
  content = content.trim();
  if (content.isEmpty && closed) return;
  parts.add(TagFoldPart(title: title, content: content, closed: closed));
}

final RegExp _anyOpenTag = RegExp(r'<([^\s<>/!?]{1,30})(?:\s[^<>]*)?>');

/// 代码块以外、完整闭合、位于顶层、不在映射里也不是 HTML 结构的标签
/// （ADR0048）。用于“聊天中发现”提示与唯一外壳去壳，不自动生效。
List<({String name, int innerLength})> findUnknownTopLevelTags(
  String text,
  TagPresentationMap map,
) {
  if (!text.contains('<')) return const [];
  final masked = _maskCode(text);
  final lower = masked.toLowerCase();
  final found = <({String name, int innerLength})>[];
  var cursor = 0;
  while (cursor < masked.length) {
    final open = _anyOpenTag.allMatches(masked, cursor).firstOrNull;
    if (open == null) break;
    final name = open.group(1)!.toLowerCase();
    final close = lower.indexOf('</$name>', open.end);
    if (close < 0) {
      cursor = open.end;
      continue;
    }
    if (!map.containsKey(name) &&
        !htmlStructureTagNames.contains(name) &&
        name != 'tts' &&
        name != 'image') {
      found.add((
        name: name,
        innerLength: masked.substring(open.end, close).trim().length,
      ));
    }
    // 只看顶层：跳过整个元素。
    cursor = close + name.length + 3;
  }
  return found;
}

/// 无损兜底（ADR0048）：回复里只有一个未知外层标签、且它包着可见正文的
/// 一半以上时，返回它的名字，调用方按正文去壳；其他情况一律原样显示。
String? soleUnknownBodyWrapper(String text, TagPresentationMap map) {
  final unknown = findUnknownTopLevelTags(text, map);
  if (unknown.length != 1) return null;
  final visible = _project(_maskCode(text), map)
      .whereType<TagBodyPart>()
      .fold<int>(0, (sum, part) => sum + part.text.length);
  final wrapper = unknown.single;
  // 可见正文里扣掉这个外壳自身的开闭标签再比较。
  final prose = visible - (wrapper.name.length * 2 + 5);
  return wrapper.innerLength * 2 >= prose ? wrapper.name : null;
}
