import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';

/// 引用块组件（MoeQuoteBlock）：气泡内或输入区上方展示「被引用的那句话」。
///
/// 左侧一条圆头竖线，右侧摘要文字，整体是一块浅色 G2 圆角内嵌面。颜色全部从
/// [foregroundColor] 派生，放在任何底色的气泡里都协调；只负责展示，不解析文本，
/// 引用格式由 `features/chat/domain/quoted_reply.dart` 统一处理。
class MoeQuoteBlock extends StatelessWidget {
  const MoeQuoteBlock({
    super.key,
    required this.text,
    required this.foregroundColor,
    this.label,
    this.accentColor,
    this.fontSize = 13,
    this.maxLines = 2,
    this.radius = 10,
  });

  /// 被引用内容的摘要。
  final String text;

  /// 文字基准色；底色、竖线与摘要色都按它的透明度派生。
  final Color foregroundColor;

  /// 摘要上方的小标题（如「回复 TA」），为空时不显示。
  final String? label;

  /// 竖线与小标题的强调色；为空时用 [foregroundColor] 的弱化色。
  final Color? accentColor;
  final double fontSize;
  final int maxLines;

  /// 内嵌面圆角；放在气泡里时按「外圆角 − 内边距」传入。
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fg = foregroundColor;
    final accent = accentColor ?? fg.withValues(alpha: 0.6);
    return Semantics(
      label: '引用：$text',
      excludeSemantics: true,
      child: Container(
        decoration: MoeG2Decoration(
          radius: radius,
          color: fg.withValues(alpha: 0.12),
        ),
        padding: const EdgeInsets.fromLTRB(7, 6, 10, 6),
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (label != null) ...[
                      Text(
                        label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent,
                          fontSize: fontSize - 1,
                          height: 1.3,
                          fontWeight: MoeFontWeights.emphasis,
                        ),
                      ),
                      const SizedBox(height: 1),
                    ],
                    Text(
                      text,
                      maxLines: maxLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.78),
                        fontSize: fontSize,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
