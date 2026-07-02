/// MoeEmptyState - 空状态占位组件
/// 
/// 用于列表为空、搜索无结果等场景。
/// 
/// 设计特点：
/// - 居中显示
/// - 图标 + 标题 + 描述 + 可选操作按钮
/// - 颜色跟随主题
/// 
/// 使用示例：
/// ```dart
/// MoeEmptyState(
///   icon: Icons.inbox_outlined,
///   title: '暂无消息',
///   description: '当有新消息时，这里会显示',
///   action: MoePrimaryButton(
///     label: '刷新',
///     onPressed: () => refresh(),
///   ),
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建空状态组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 空状态占位组件
class MoeEmptyState extends StatelessWidget {
  const MoeEmptyState({
    super.key,
    this.icon,
    required this.title,
    this.description,
    this.action,
    // === 样式接口 ===
    this.iconSize = 64,
    this.iconColor,
    this.titleStyle,
    this.descriptionStyle,
    this.padding,
  });

  /// 图标（可选）
  final IconData? icon;

  /// 标题
  final String title;

  /// 描述文字（可选）
  final String? description;

  /// 操作按钮（可选）
  final Widget? action;

  // === 样式接口 ===
  
  /// 图标大小
  final double iconSize;

  /// 图标颜色
  final Color? iconColor;

  /// 标题样式
  final TextStyle? titleStyle;

  /// 描述样式
  final TextStyle? descriptionStyle;

  /// 内边距
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final defaultPadding = padding ?? const EdgeInsets.all(32);

    return Padding(
      padding: defaultPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 图标
          if (icon != null) ...[
            Icon(
              icon,
              size: iconSize,
              color: iconColor ?? colors.muted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
          ],
          
          // 标题
          Text(
            title,
            style: titleStyle ?? TextStyle(
              fontSize: 16,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
            textAlign: TextAlign.center,
          ),
          
          // 描述
          if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              style: descriptionStyle ?? TextStyle(
                fontSize: 14,
                color: colors.muted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          
          // 操作按钮
          if (action != null) ...[
            const SizedBox(height: 24),
            action!,
          ],
        ],
      ),
    );
  }
}
