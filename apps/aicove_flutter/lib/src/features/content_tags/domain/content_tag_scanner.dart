import 'content_tag_registry.dart';
import 'content_tag_spec.dart';

sealed class ContentTagSegment {
  const ContentTagSegment(this.start);

  /// 在被扫描文本中的起始偏移。
  final int start;

  /// 原样文本。
  String get raw;

  int get end => start + raw.length;
}

/// 标签之外的普通文本。
class ContentTagText extends ContentTagSegment {
  const ContentTagText(super.start, this.text);
  final String text;

  @override
  String get raw => text;
}

/// 一个已注册标签的完整元素（或流式中尚未闭合的元素）。
class ContentTagElement extends ContentTagSegment {
  const ContentTagElement(
    super.start, {
    required this.spec,
    required this.openTag,
    required this.inner,
    required this.closeTag,
    required this.closed,
    required this.selfClosing,
  });

  final ContentTagSpec spec;

  /// 原样开标签，如 `<TTS voice="a">`。
  final String openTag;

  /// 原样正文；同名嵌套保留在内，其他标签需要时由调用方再次扫描。
  final String inner;

  /// 原样闭标签；未闭合或自闭合时为空。
  final String closeTag;

  /// false 表示开标签之后直到文本末尾都没有配对闭标签（流式截断或模型漏写）。
  final bool closed;
  final bool selfClosing;

  bool get hasAttributes => attributes.isNotEmpty;

  Map<String, String> get attributes {
    final result = <String, String>{};
    final body = openTag.replaceFirst(_openNamePattern, '');
    for (final match in _attributePattern.allMatches(body)) {
      final value = match.group(2) ?? match.group(3) ?? match.group(4) ?? '';
      result[match.group(1)!.toLowerCase()] = value;
    }
    return result;
  }

  @override
  String get raw => '$openTag$inner$closeTag';

  static final RegExp _openNamePattern = RegExp(r'^<[^\s/>]+');
  static final RegExp _attributePattern = RegExp(
    '([^\\s=/>"\']+)(?:\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s"\'>]+)))?',
  );
}

/// 没有对应开标签的闭标签。
class ContentTagOrphanClose extends ContentTagSegment {
  const ContentTagOrphanClose(
    super.start, {
    required this.spec,
    required this.closeTag,
  });
  final ContentTagSpec spec;
  final String closeTag;

  @override
  String get raw => closeTag;
}

/// 唯一的语义标签扫描器（ADR0044）。
///
/// 口径：大小写不敏感；允许属性（带引号的值可含 `>`）；同一标签按深度配对嵌套；
/// 支持自闭合；未闭合的开标签吞到文本末尾并标记 [ContentTagElement.closed] 为
/// false；孤立闭标签单独成段；未注册的 `<xxx>` 当普通文本。
class ContentTagScanner {
  ContentTagScanner(this.registry) : _pattern = _buildPattern(registry.tagNames);

  final ContentTagRegistry registry;
  final RegExp? _pattern;

  static RegExp? _buildPattern(Iterable<String> names) {
    final sorted = names.toList()..sort((a, b) => b.length.compareTo(a.length));
    if (sorted.isEmpty) return null;
    final alternatives = sorted.map(RegExp.escape).join('|');
    return RegExp(
      '<(/?)($alternatives)(?=[\\s/>])(?:"[^"]*"|\'[^\']*\'|[^\'">])*?>',
      caseSensitive: false,
    );
  }

  List<ContentTagSegment> scan(String text) => _scan(text, 0);

  List<ContentTagSegment> _scan(String text, int base) {
    final pattern = _pattern;
    if (pattern == null || !text.contains('<')) {
      return text.isEmpty ? const [] : [ContentTagText(base, text)];
    }
    final segments = <ContentTagSegment>[];
    var cursor = 0;
    void flushText(int end) {
      if (end > cursor) {
        segments.add(
          ContentTagText(base + cursor, text.substring(cursor, end)),
        );
      }
    }

    ContentTagSpec? active;
    RegExpMatch? open;
    var depth = 0;
    for (final match in pattern.allMatches(text)) {
      final spec = registry.lookup(match.group(2)!)!;
      final closing = match.group(1) == '/';
      final selfClosing = !closing && match.group(0)!.endsWith('/>');
      if (active == null) {
        flushText(match.start);
        cursor = match.end;
        if (closing) {
          segments.add(
            ContentTagOrphanClose(
              base + match.start,
              spec: spec,
              closeTag: match.group(0)!,
            ),
          );
        } else if (selfClosing) {
          segments.add(ContentTagElement(
            base + match.start,
            spec: spec,
            openTag: match.group(0)!,
            inner: '',
            closeTag: '',
            closed: true,
            selfClosing: true,
          ));
        } else {
          active = spec;
          open = match;
          depth = 1;
        }
        continue;
      }
      if (!identical(spec, active)) continue;
      if (closing) {
        depth--;
        if (depth == 0) {
          segments.add(ContentTagElement(
            base + open!.start,
            spec: active,
            openTag: open.group(0)!,
            inner: text.substring(open.end, match.start),
            closeTag: match.group(0)!,
            closed: true,
            selfClosing: false,
          ));
          cursor = match.end;
          active = null;
          open = null;
        }
      } else if (!selfClosing) {
        depth++;
      }
    }
    if (active != null) {
      // 到结尾都没闭合：若其后还有完整标签，说明这是正文里顺口提到的标签名
      // （如思维链里写“这轮要用<tts>”），当普通文字并继续扫描，避免吞掉后文；
      // 否则才是流式输出中尚未写完的元素。
      final rest = _scan(text.substring(open!.end), base + open.end);
      final stray = rest.any(
        (segment) =>
            (segment is ContentTagElement && segment.closed) ||
            segment is ContentTagOrphanClose,
      );
      if (stray) {
        segments
          ..add(ContentTagText(base + open.start, open.group(0)!))
          ..addAll(rest);
      } else {
        segments.add(ContentTagElement(
          base + open.start,
          spec: active,
          openTag: open.group(0)!,
          inner: text.substring(open.end),
          closeTag: '',
          closed: false,
          selfClosing: false,
        ));
      }
    } else {
      flushText(text.length);
    }
    return segments;
  }

  /// 按注册表生成请求副本文本；保留的元素会递归过滤其正文。
  String filterForRequest(String text) {
    if (_pattern == null || !text.contains('<')) return text;
    final output = StringBuffer();
    for (final segment in scan(text)) {
      switch (segment) {
        case ContentTagText(:final text):
          output.write(text);
        case ContentTagOrphanClose(:final spec, :final closeTag):
          if (registry.requestAction(spec) == ContentTagRequestAction.keep) {
            output.write(closeTag);
          }
        case ContentTagElement():
          switch (registry.requestAction(segment.spec)) {
            case ContentTagRequestAction.strip:
              break;
            case ContentTagRequestAction.unwrap:
              output.write(filterForRequest(segment.inner));
            case ContentTagRequestAction.keep:
              output
                ..write(segment.openTag)
                ..write(filterForRequest(segment.inner))
                ..write(segment.closeTag);
          }
      }
    }
    return output.toString();
  }
}
