/// MoeSettingsGroup - 设置分组卡片组件
/// 
/// 用于设置页面的分组容器，包裹多个 MoeSettingsRow。
/// 
/// 设计特点：
/// - iOS 风格分组卡片
/// - 可选的分组标题
/// - 圆角、边框、阴影可自定义
/// - 自动处理最后一行的分割线
/// 
/// 使用示例：
/// ```dart
/// MoeSettingsGroup(
///   title: '通用设置',
///   children: [
///     MoeSettingsRow(icon: Icons.language, label: '语言'),
///     MoeSettingsRow(icon: Icons.palette, label: '主题'),
///   ],
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建设置分组组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';
import 'moe_settings_row.dart';

/// 设置分组卡片组件
class MoeSettingsGroup extends StatelessWidget {
  const MoeSettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.titleFirst = false,
    // === 样式接口 ===
    this.backgroundColor,
    this.borderRadius,
    this.border,
    this.boxShadow,
    this.margin,
    this.padding,
    this.titleStyle,
    this.titleColor,
    this.titlePadding,
  });

  /// 分组标题（可选）
  final String? title;

  /// 子组件列表（通常是 MoeSettingsRow）
  final List<Widget> children;

  /// 是否为第一个分组（影响标题上边距）
  final bool titleFirst;

  // === 样式接口 ===
  
  /// 卡片背景色
  final Color? backgroundColor;

  /// 卡片圆角
  final BorderRadius? borderRadius;

  /// 卡片边框
  final BorderSide? border;

  /// 卡片阴影
  final List<BoxShadow>? boxShadow;

  /// 卡片外边距
  final EdgeInsets? margin;

  /// 内容内边距
  final EdgeInsets? padding;

  /// 标题样式
  final TextStyle? titleStyle;

  /// 标题颜色
  final Color? titleColor;

  /// 标题内边距
  final EdgeInsets? titlePadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 解析样式 - 卡片背景使用主题的组件公共背景色
    final bgColor = backgroundColor ?? colors.componentBackground;
    final radius = borderRadius ?? MoeRadii.borderMd;
    final g2Radius = radius.topLeft.x;
    final borderSide = border ?? BorderSide(
      color: colors.border.withValues(alpha: 0.06),
      width: 0.6,
    );
    final shadow = boxShadow ?? MoeShadows.soft;
    final outerMargin = margin ?? const EdgeInsets.symmetric(horizontal: 16);
    final innerPadding = padding ?? const EdgeInsets.symmetric(vertical: 4);
    final titleMargin = titlePadding ?? EdgeInsets.only(
      left: 16,
      right: 16,
      top: titleFirst ? 2 : 12,
      bottom: 8,
    );
    final defaultTitleStyle = titleStyle ?? TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: titleColor ?? colors.textSecondary.withValues(alpha: 0.8),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 分组标题
        if (title != null)
          Padding(
            padding: titleMargin,
            child: Text(title!, style: defaultTitleStyle),
          ),
        
        // 卡片容器
        Container(
          margin: outerMargin,
          decoration: MoeG2Decoration(
            radius: g2Radius,
            color: bgColor,
            border: Border.fromBorderSide(borderSide),
            boxShadow: shadow,
          ),
          child: MoeG2ClipRRect(
            radius: g2Radius,
            child: Padding(
              padding: innerPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _processChildren(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 处理子组件，确保最后一个不显示分割线
  List<Widget> _processChildren() {
    if (children.isEmpty) return children;
    
    return children.asMap().entries.map((entry) {
      final index = entry.key;
      final child = entry.value;
      final isLast = index == children.length - 1;
      
      // 如果是 MoeSettingsRow 且是最后一个，隐藏分割线
      if (isLast && child is MoeSettingsRow) {
        return MoeSettingsRow(
          key: child.key,
          icon: child.icon,
          iconWidget: child.iconWidget,
          label: child.label,
          labelMaxLines: child.labelMaxLines,
          subtitle: child.subtitle,
          trailingType: child.trailingType,
          trailing: child.trailing,
          detailText: child.detailText,
          switchValue: child.switchValue,
          onSwitchChanged: child.onSwitchChanged,
          onTap: child.onTap,
          enabled: child.enabled,
          showDivider: false, // 最后一个不显示分割线
          iconColor: child.iconColor,
          labelColor: child.labelColor,
          subtitleColor: child.subtitleColor,
          backgroundColor: child.backgroundColor,
          pressedBackgroundColor: child.pressedBackgroundColor,
          dividerColor: child.dividerColor,
          iconSize: child.iconSize,
          iconContainerWidth: child.iconContainerWidth,
          contentPadding: child.contentPadding,
        );
      }
      
      return child;
    }).toList();
  }
}
