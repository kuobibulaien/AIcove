import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';
import 'moe_toast.dart';

/// 代码块组件（MoeCodeBlock）：语言名 + 复制按钮 + 语法高亮，超宽横向滚动。
///
/// 底色取前景色的淡叠加，放进任何气泡或页面背景都能分层；高亮只注册常用语言，
/// 未知或未标注语言按纯文本显示。只负责展示，不解析 Markdown，代码由调用方传入。
class MoeCodeBlock extends StatefulWidget {
  const MoeCodeBlock({
    super.key,
    required this.code,
    this.language = '',
    this.foregroundColor,
    this.fontSize = 13,
  });

  final String code;

  /// 围栏 info string 的第一个词，如 `dart`、`py`；为空时不显示语言名。
  final String language;

  /// 未高亮文字与标题栏颜色；为空时取主题正文色。
  final Color? foregroundColor;
  final double fontSize;

  @override
  State<MoeCodeBlock> createState() => _MoeCodeBlockState();
}

class _MoeCodeBlockState extends State<MoeCodeBlock> {
  TextSpan? _span;
  String? _spanKey;

  TextSpan _highlighted(TextStyle base, Brightness brightness) {
    final key = '${brightness.name}|${widget.language}|'
        '${base.color?.toARGB32()}|${base.fontSize}|${widget.code}';
    if (_spanKey == key && _span != null) return _span!;
    _spanKey = key;
    return _span = highlightCode(
      widget.code,
      language: widget.language,
      base: base,
      brightness: brightness,
    );
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.lightImpact();
    MoeToast.brief(context, '已复制代码');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final fg = widget.foregroundColor ?? colors.text;
    // 高亮配色跟随代码所在底色而不是应用明暗：浅色字说明底色深（如深色气泡）。
    final brightness = fg.computeLuminance() > 0.5
        ? Brightness.dark
        : Brightness.light;
    final bodyFont = DefaultTextStyle.of(context).style.fontFamily ??
        Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final codeStyle = TextStyle(
      color: fg,
      fontFamily: 'Menlo',
      // 等宽字体没有中文字形：先回落到正文字体，中文与正文一致。
      fontFamilyFallback: [
        if (bodyFont != null) bodyFont,
        'SF Mono',
        'Consolas',
        'monospace',
      ],
      fontSize: widget.fontSize,
      height: 1.45,
    );
    final language = widget.language.trim();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: MoeG2Decoration(
        radius: 10,
        color: fg.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('moe_code_block_copy'),
                  tooltip: '复制代码',
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  color: fg.withValues(alpha: 0.6),
                  onPressed: _copy,
                  icon: const Icon(Icons.content_copy_rounded),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text.rich(
              _highlighted(codeStyle, brightness),
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}

final Highlight _highlight = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'go': langGo,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'php': langPhp,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

/// 按语言高亮代码；未注册的语言返回纯文本。高亮主题去掉自带底色，由容器统一提供。
TextSpan highlightCode(
  String code, {
  required String language,
  required TextStyle base,
  required Brightness brightness,
}) {
  final name = language.trim().toLowerCase();
  if (name.isEmpty || _highlight.getLanguage(name) == null) {
    return TextSpan(text: code, style: base);
  }
  final theme = brightness == Brightness.dark ? githubDarkTheme : githubTheme;
  final renderer = TextSpanRenderer(base, {
    for (final entry in theme.entries)
      if (entry.key != 'root') entry.key: entry.value.copyWith(
        backgroundColor: Colors.transparent,
      ),
  });
  try {
    _highlight.highlight(code: code, language: name).render(renderer);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
  return renderer.span ?? TextSpan(text: code, style: base);
}
