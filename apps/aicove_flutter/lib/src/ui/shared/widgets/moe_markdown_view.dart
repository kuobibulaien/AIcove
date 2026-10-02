import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../theme/tokens.dart';
import 'moe_code_block.dart';

/// Markdown 正文组件（MoeMarkdownView）：文档模式下助手消息的唯一渲染入口（ADR0047）。
///
/// 薄封装 `gpt_markdown`，只负责项目口径：配色与字号取主题，围栏代码交给
/// [MoeCodeBlock]，链接只上样式不跳转，图片只显示占位文字不发起网络加载，
/// 公式按原文显示。不自行解析 Markdown。
class MoeMarkdownView extends StatelessWidget {
  const MoeMarkdownView(
    this.data, {
    super.key,
    this.fontSize = 15,
    this.color,
  });

  final String data;
  final double fontSize;

  /// 正文颜色；为空时取主题正文色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final fg = color ?? colors.text;
    final brightness = Theme.of(context).brightness;
    final base = TextStyle(
      color: fg,
      fontSize: fontSize,
      height: 1.6,
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
    );
    TextStyle heading(double scale) => base.copyWith(
          fontSize: fontSize * scale,
          fontWeight: FontWeight.w600,
          height: 1.4,
        );

    return GptMarkdownTheme(
      gptThemeData: GptMarkdownThemeData(
        brightness: brightness,
        highlightColor: fg.withValues(alpha: 0.08),
        h1: heading(1.45),
        h2: heading(1.3),
        h3: heading(1.15),
        h4: heading(1.05),
        h5: heading(1.0),
        h6: heading(1.0),
        hrLineColor: colors.divider,
        linkColor: colors.primary,
        linkHoverColor: colors.primary,
      ),
      child: GptMarkdown(
        data,
        style: base,
        styleSheet: GptMarkdownStyleSheet(
          table: TableStyle(
            borderColor: colors.divider,
            borderWidth: 1,
            borderRadius: const Radius.circular(8),
            cellPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            headerBackground: fg.withValues(alpha: 0.05),
            headerTextStyle: base.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        codeBuilder: (context, language, code, closed) => MoeCodeBlock(
          code: code,
          language: language,
          foregroundColor: fg,
          fontSize: fontSize - 2,
        ),
        imageBuilder: (context, url, width, height) => Text(
          '［图片］',
          style: base.copyWith(color: fg.withValues(alpha: 0.55)),
        ),
        latexBuilder: (context, tex, textStyle, inline) =>
            Text(tex, style: textStyle),
      ),
    );
  }
}
