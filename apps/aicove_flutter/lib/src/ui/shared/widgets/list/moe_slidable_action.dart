import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../../theme/tokens.dart';
import '../buttons/moe_button_surface.dart';

/// 左滑操作按钮：替代 flutter_slidable 自带的实色 [SlidableAction]。
///
/// 每个操作是一块跟随全局材质的圆角按钮，强调色淡染；危险操作改用
/// 错误色淡染。文字始终用主题文字色，保证在壁纸和模糊背景上可读。
/// 必须作为 [ActionPane.children] 的直接子项使用。
class MoeSlidableAction extends StatelessWidget {
  const MoeSlidableAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.flex = 1,
    this.autoClose = true,
  });

  final IconData icon;
  final String label;
  final ValueChanged<BuildContext> onPressed;
  final bool destructive;
  final int flex;
  final bool autoClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final tone = destructive ? colors.toastError : colors.primary;
    final iconColor = destructive ? colors.toastError : context.moeAccentInk;
    return Expanded(
      flex: flex,
      child: Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.lightImpact();
            onPressed(context);
            if (autoClose) Slidable.of(context)?.close();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: MoeButtonSurface(
              shareParentSurface: false,
              radius: 14,
              tintColor: tone.withValues(alpha: 0.18),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: iconColor),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: MoeFontWeights.emphasis,
                      color: colors.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
