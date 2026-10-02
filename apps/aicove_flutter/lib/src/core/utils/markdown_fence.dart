/// Markdown 围栏代码块（CommonMark fenced code block）。
///
/// [start, end) 是代码块在原文中的区间，含开、闭围栏行（不含闭栏后的换行）。
/// 未闭合的代码块延伸到原文末尾，[closed] 为 false（流式中正在写）。
class FencedCodeBlock {
  const FencedCodeBlock({
    required this.start,
    required this.end,
    required this.language,
    required this.code,
    required this.closed,
  });

  final int start;
  final int end;

  /// info string 的第一个词，没有时为空串。
  final String language;

  /// 开、闭围栏之间的代码，不含两端围栏行。
  final String code;
  final bool closed;
}

final RegExp _openingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final RegExp _closingFence = RegExp(r'^ {0,3}(`{3,}|~{3,})[ \t]*$');

/// 按行扫描围栏代码块（ADR0047 分段保护区）。
///
/// - 开栏：行首至多 3 个空格，随后至少 3 个 `` ` `` 或 `~`，可带 info string；
///   反引号围栏的 info string 不能再含反引号。
/// - 闭栏：同一字符、长度不短于开栏，其后只有空白。
/// - 没有闭栏时延伸到文末。
List<FencedCodeBlock> scanFencedCodeBlocks(String text) {
  if (!text.contains('```') && !text.contains('~~~')) return const [];
  final blocks = <FencedCodeBlock>[];
  var lineStart = 0;
  int? openStart;
  var fenceChar = '';
  var fenceLength = 0;
  var language = '';
  var codeStart = 0;

  while (lineStart <= text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? text.length : newline;
    var line = text.substring(lineStart, lineEnd);
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

    if (openStart == null) {
      final match = _openingFence.firstMatch(line);
      if (match != null) {
        final fence = match.group(1)!;
        final info = match.group(2)!.trim();
        if (!(fence.startsWith('`') && info.contains('`'))) {
          openStart = lineStart;
          fenceChar = fence[0];
          fenceLength = fence.length;
          language = info.split(RegExp(r'\s+')).first;
          codeStart = newline < 0 ? text.length : newline + 1;
        }
      }
    } else {
      final match = _closingFence.firstMatch(line);
      final fence = match?.group(1);
      if (fence != null &&
          fence[0] == fenceChar &&
          fence.length >= fenceLength) {
        blocks.add(FencedCodeBlock(
          start: openStart,
          end: lineEnd,
          language: language,
          code: _stripTrailingNewline(
            text.substring(codeStart, lineStart.clamp(codeStart, text.length)),
          ),
          closed: true,
        ));
        openStart = null;
      }
    }

    if (newline < 0) break;
    lineStart = newline + 1;
  }

  if (openStart != null) {
    blocks.add(FencedCodeBlock(
      start: openStart,
      end: text.length,
      language: language,
      code: text.substring(codeStart.clamp(0, text.length)),
      closed: false,
    ));
  }
  return blocks;
}

String _stripTrailingNewline(String value) {
  if (value.endsWith('\r\n')) return value.substring(0, value.length - 2);
  if (value.endsWith('\n')) return value.substring(0, value.length - 1);
  return value;
}

/// 按围栏代码块把文本切成「正文 / 代码」交替片段，供气泡等纯文本渲染处使用。
/// 正文片段去掉与代码块相邻的那个换行，其余原样保留；空正文片段丢弃。
List<FencedTextPart> splitFencedText(String text) {
  final blocks = scanFencedCodeBlocks(text);
  if (blocks.isEmpty) return [FencedProsePart(text)];
  final parts = <FencedTextPart>[];
  var cursor = 0;
  void addProse(String value) {
    var prose = value;
    if (prose.startsWith('\r\n')) {
      prose = prose.substring(2);
    } else if (prose.startsWith('\n')) {
      prose = prose.substring(1);
    }
    if (prose.endsWith('\r\n')) {
      prose = prose.substring(0, prose.length - 2);
    } else if (prose.endsWith('\n')) {
      prose = prose.substring(0, prose.length - 1);
    }
    if (prose.trim().isNotEmpty) parts.add(FencedProsePart(prose));
  }

  for (final block in blocks) {
    addProse(text.substring(cursor, block.start));
    parts.add(FencedCodePart(block));
    cursor = block.end;
  }
  addProse(text.substring(cursor));
  return parts;
}

sealed class FencedTextPart {
  const FencedTextPart();
}

class FencedProsePart extends FencedTextPart {
  const FencedProsePart(this.text);
  final String text;
}

class FencedCodePart extends FencedTextPart {
  const FencedCodePart(this.block);
  final FencedCodeBlock block;
}
