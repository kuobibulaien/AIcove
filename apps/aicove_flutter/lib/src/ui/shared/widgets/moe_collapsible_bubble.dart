import 'package:flutter/material.dart';

import '../../theme/skin_provider.dart';
import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';

/// 消息气泡共用外观参数：聊天消息气泡与折叠气泡等同风格气泡统一引用。
class MoeBubbleStyle {
  MoeBubbleStyle._();

  static const double defaultFontSize = 15.0;
  static const double textHeight = 1.42;
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 7,
  );
}

/// 折叠气泡组件（MoeCollapsibleBubble）：独立消息气泡，默认只显示标题行，点击展开正文。
///
/// 外观（底色、圆角、内边距、字号、行高）与聊天消息气泡共用 [MoeBubbleStyle]，
/// 折叠时高度与单行消息气泡一致。只负责展示与展开状态，不解析文本；
/// 正则或其他规则产出的 `title` / `content` 由调用方传入。
class MoeCollapsibleBubble extends StatefulWidget {
  const MoeCollapsibleBubble({
    super.key,
    required this.isMe,
    required this.title,
    required this.content,
    this.child,
    this.leadingIcon,
    this.fontSize = MoeBubbleStyle.defaultFontSize,
    this.backgroundColor,
    this.foregroundColor,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.animationDuration = const Duration(milliseconds: 200),
    this.animationCurve = Curves.easeInOut,
  });

  /// 决定默认配色，与聊天消息气泡的左右侧一致。
  final bool isMe;

  /// 标题栏：折叠时在外显示的一行文字，超长省略。
  final String title;

  /// 正文：展开后显示。
  final String content;

  /// 可选的自定义正文组件（如带格式的文字、表格、图片）；
  /// 提供时展开后显示它代替 [content] 的纯文本，[content] 仍作为正文原文保留。
  final Widget? child;

  /// 标题前的图标，为空时不显示。
  final IconData? leadingIcon;
  final double fontSize;

  /// 覆盖默认气泡底色 / 前景色；为空时跟随主题中的左右气泡配色。
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final Duration animationDuration;
  final Curve animationCurve;

  @override
  State<MoeCollapsibleBubble> createState() => _MoeCollapsibleBubbleState();
}

class _MoeCollapsibleBubbleState extends State<MoeCollapsibleBubble> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final bg =
        widget.backgroundColor ??
        (widget.isMe ? colors.bubbleRightBg : colors.bubbleLeftBg);
    final fg =
        widget.foregroundColor ??
        (widget.isMe ? Colors.white : colors.bubbleLeftFg);
    final textStyle = TextStyle(
      color: fg,
      fontSize: widget.fontSize,
      height: MoeBubbleStyle.textHeight,
    );
    // 图标不受 textScaler 影响，按全局字号缩放后与文字行高对齐。
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(widget.fontSize) *
        MoeBubbleStyle.textHeight;

    return Semantics(
      button: true,
      expanded: _expanded,
      child: GestureDetector(
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: MoeBubbleStyle.padding,
          decoration: MoeG2Decoration(
            radius: context.skin.bubbleRadius,
            color: bg,
          ),
          child: AnimatedSize(
            duration: widget.animationDuration,
            curve: widget.animationCurve,
            alignment: widget.isMe ? Alignment.topRight : Alignment.topLeft,
            // 标题行随正文宽度撑开，展开按钮保持在最右侧。
            child: IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (widget.leadingIcon != null) ...[
                        Icon(
                          widget.leadingIcon,
                          size: lineHeight * 0.8,
                          color: fg.withValues(alpha: 0.72),
                        ),
                        SizedBox(width: lineHeight * 0.25),
                      ],
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textStyle.copyWith(
                            fontWeight: MoeFontWeights.emphasis,
                          ),
                        ),
                      ),
                      SizedBox(width: lineHeight * 0.3),
                      _ExpandButton(
                        expanded: _expanded,
                        // 略小于行高，保证气泡高度只由文字决定。
                        size: lineHeight * 0.9,
                        color: fg,
                        duration: widget.animationDuration,
                        curve: widget.animationCurve,
                      ),
                    ],
                  ),
                  if (_expanded) ...[
                    Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: lineHeight * 0.25,
                      ),
                      child: Divider(
                        height: 0.5,
                        thickness: 0.5,
                        color: fg.withValues(alpha: 0.18),
                      ),
                    ),
                    widget.child ?? Text(widget.content, style: textStyle),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题行右侧的展开小按钮，尺寸不超过一行文字高度，不改变气泡高度。
class _ExpandButton extends StatelessWidget {
  const _ExpandButton({
    required this.expanded,
    required this.size,
    required this.color,
    required this.duration,
    required this.curve,
  });

  final bool expanded;
  final double size;
  final Color color;
  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.14),
      ),
      child: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: duration,
        curve: curve,
        child: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: size * 0.85,
          color: color.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}
