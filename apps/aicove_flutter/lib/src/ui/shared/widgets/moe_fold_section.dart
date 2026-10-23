import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'moe_collapsible_bubble.dart';

/// 半隐藏折叠段（MoeFoldSection）：文档模式里的思维链、状态栏等折叠内容。
///
/// 不画底色和边框，折叠时只有一行淡色小字标题加箭头；展开后正文同样淡色、
/// 字号小一号，左侧一条细竖线和正文区分开。只负责展示与展开状态，
/// 标题和正文由调用方传入。
class MoeFoldSection extends StatefulWidget {
  const MoeFoldSection({
    super.key,
    required this.title,
    required this.content,
    this.child,
    this.leadingIcon,
    this.fontSize = MoeBubbleStyle.defaultFontSize,
    this.foregroundColor,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.animationDuration = const Duration(milliseconds: 200),
    this.animationCurve = Curves.easeInOut,
  });

  /// 标题和正文的透明度：比正文淡，一眼能和正文区分。
  static const double titleAlpha = 0.55;
  static const double bodyAlpha = 0.68;

  /// 标题：折叠时唯一显示的一行，超长省略。
  final String title;

  /// 正文原文：未提供 [child] 时按纯文本显示。
  final String content;

  /// 可选的自定义正文组件（如 Markdown）；调用方负责让它的颜色跟 [bodyColor] 一致。
  final Widget? child;
  final IconData? leadingIcon;

  /// 正文字号；标题和展开后的正文都比它小一号。
  final double fontSize;

  /// 基准前景色，为空时用主题正文色；标题和正文在它上面降透明度。
  final Color? foregroundColor;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final Duration animationDuration;
  final Curve animationCurve;

  /// 展开后正文应使用的颜色，供调用方构造 [child] 时取用。
  static Color bodyColor(BuildContext context, [Color? foreground]) =>
      (foreground ?? context.moeColors.text).withValues(alpha: bodyAlpha);

  @override
  State<MoeFoldSection> createState() => _MoeFoldSectionState();
}

class _MoeFoldSectionState extends State<MoeFoldSection> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.foregroundColor ?? context.moeColors.text;
    final titleColor = fg.withValues(alpha: MoeFoldSection.titleAlpha);
    final smallSize = widget.fontSize - 1;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(smallSize) *
        MoeBubbleStyle.textHeight;

    final header = Semantics(
      button: true,
      expanded: _expanded,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.leadingIcon != null) ...[
                  Icon(
                    widget.leadingIcon,
                    size: lineHeight * 0.8,
                    color: titleColor,
                  ),
                  SizedBox(width: lineHeight * 0.3),
                ],
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: smallSize,
                      height: MoeBubbleStyle.textHeight,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: widget.animationDuration,
                  curve: widget.animationCurve,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: lineHeight,
                    color: titleColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return AnimatedSize(
      duration: widget.animationDuration,
      curve: widget.animationCurve,
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (_expanded)
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 2, left: 2),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: fg.withValues(alpha: 0.16), width: 2),
                ),
              ),
              child:
                  widget.child ??
                  Text(
                    widget.content,
                    style: TextStyle(
                      color: MoeFoldSection.bodyColor(context, fg),
                      fontSize: smallSize,
                      height: MoeBubbleStyle.textHeight,
                    ),
                  ),
            ),
        ],
      ),
    );
  }
}
