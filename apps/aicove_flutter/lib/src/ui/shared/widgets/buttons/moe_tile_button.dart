/// MoeTileButton - 功能入口按钮组件
/// 
/// 用于设置项、功能卡片等场景。
/// 
/// 设计特点：
/// - 类似设置行的布局（图标 + 标题 + 副标题）
/// - 但作为独立按钮使用
/// - iOS 风格交互
/// - 完整的样式接口
/// 
/// 使用示例：
/// ```dart
/// MoeTileButton(
///   icon: Icons.language,
///   label: '语言设置',
///   subtitle: '选择应用语言',
///   onTap: () => openLanguageSettings(),
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建功能入口按钮组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 功能入口按钮组件
class MoeTileButton extends StatefulWidget {
  const MoeTileButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.showChevron = true,
    this.enabled = true,
    // === 样式接口 ===
    this.backgroundColor,
    this.pressedBackgroundColor,
    this.iconColor,
    this.labelColor,
    this.subtitleColor,
    this.borderRadius,
    this.border,
    this.boxShadow,
    this.contentPadding,
  });

  /// 按钮文字
  final String label;

  /// 左侧图标
  final IconData icon;

  /// 点击回调
  final VoidCallback? onTap;

  /// 副标题（可选）
  final String? subtitle;

  /// 右侧自定义控件（如 Switch）
  final Widget? trailing;

  /// 是否显示右侧箭头
  final bool showChevron;

  /// 是否启用
  final bool enabled;

  // === 样式接口 ===
  
  final Color? backgroundColor;
  final Color? pressedBackgroundColor;
  final Color? iconColor;
  final Color? labelColor;
  final Color? subtitleColor;
  final BorderRadius? borderRadius;
  final BorderSide? border;
  final List<BoxShadow>? boxShadow;
  final EdgeInsets? contentPadding;

  @override
  State<MoeTileButton> createState() => _MoeTileButtonState();
}

class _MoeTileButtonState extends State<MoeTileButton> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析样式
    final bgColor = widget.backgroundColor ?? colors.surface;
    final pressedBg = widget.pressedBackgroundColor ?? colors.surfaceAlt;
    final iconColor = widget.iconColor ?? colors.text;
    final labelColor = widget.labelColor ?? colors.text;
    final subtitleColor = widget.subtitleColor ?? colors.muted;
    final radius = widget.borderRadius ?? MoeRadii.borderMd;
    final g2Radius = radius.topLeft.x;
    final padding = widget.contentPadding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 14);

    final currentBg = (_pressed && _isEnabled) ? pressedBg : bgColor;

    return GestureDetector(
      onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: _isEnabled ? widget.onTap : null,
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: padding,
        decoration: MoeG2Decoration(
          radius: g2Radius,
          color: currentBg,
          border: widget.border != null ? Border.fromBorderSide(widget.border!) : null,
          boxShadow: widget.boxShadow ?? MoeShadows.soft,
        ),
        child: Row(
          children: [
            // 图标
            Icon(
              widget.icon,
              size: 24,
              color: widget.enabled ? iconColor : colors.muted,
            ),
            const SizedBox(width: 14),
            
            // 标题区
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: MoeFontWeights.emphasis,
                      color: widget.enabled ? labelColor : colors.muted,
                    ),
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.enabled ? subtitleColor : colors.muted.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            
            // 右侧控件
            if (widget.trailing != null) ...[
              const SizedBox(width: 8),
              widget.trailing!,
            ],
            
            // 箭头
            if (widget.showChevron && widget.trailing == null)
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.muted,
              ),
          ],
        ),
      ),
    );
  }
}
