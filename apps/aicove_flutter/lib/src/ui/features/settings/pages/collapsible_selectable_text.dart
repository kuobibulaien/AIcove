import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';

/// 可折叠的可选择文本组件。
///
/// 文本超过 [collapsedLines] 行时自动折叠，
/// 底部显示"展开更多"/"收起"按钮。
class CollapsibleSelectableText extends StatefulWidget {
  final String content;
  final TextStyle style;
  final int collapsedLines;
  final Color toggleColor;

  const CollapsibleSelectableText({
    super.key,
    required this.content,
    required this.style,
    this.collapsedLines = 10,
    required this.toggleColor,
  });

  @override
  State<CollapsibleSelectableText> createState() =>
      _CollapsibleSelectableTextState();
}

class _CollapsibleSelectableTextState extends State<CollapsibleSelectableText> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant CollapsibleSelectableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content && _expanded) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.content, style: widget.style),
          maxLines: widget.collapsedLines,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final canToggle = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              widget.content,
              maxLines: _expanded ? null : widget.collapsedLines,
              style: widget.style,
            ),
            if (canToggle) ...[
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? '收起' : '展开更多',
                  style: TextStyle(
                    color: widget.toggleColor,
                    fontSize: 10,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
