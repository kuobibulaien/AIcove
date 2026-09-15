import 'package:flutter/material.dart';

/// 长消息按硬换行缓存 Text 子树：追加末段时，已完成段落不再重新排版。
/// 不按字符数硬切，避免破坏软换行、字形连写和段内双向文本。
class IncrementalMessageText extends StatefulWidget {
  const IncrementalMessageText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<IncrementalMessageText> createState() => _IncrementalMessageTextState();
}

class _IncrementalMessageTextState extends State<IncrementalMessageText> {
  List<String> _lines = const [];
  List<Widget> _paragraphs = const [];

  @override
  void initState() {
    super.initState();
    _updateParagraphs();
  }

  @override
  void didUpdateWidget(IncrementalMessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _updateParagraphs(reuse: oldWidget.style == widget.style);
    }
  }

  void _updateParagraphs({bool reuse = false}) {
    final lines = widget.text.split('\n');
    final paragraphs = <Widget>[];
    for (var index = 0; index < lines.length; index++) {
      // 空 Text 在放大字体时的行高不同于正文中的空行；零宽字符让它
      // 按同一字体度量占一行。只改变绘制子树，读屏仍使用原始全文。
      paragraphs.add(
          reuse && index < _lines.length && _lines[index] == lines[index]
              ? _paragraphs[index]
              : Text(lines[index].isEmpty ? '\u200b' : lines[index],
                  style: widget.style));
    }
    _lines = lines;
    _paragraphs = paragraphs;
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: widget.text,
        textDirection: Directionality.of(context),
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _paragraphs,
        ),
      );
}
