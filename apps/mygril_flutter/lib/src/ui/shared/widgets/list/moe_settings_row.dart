/// MoeSettingsRow - 设置行组件
///
/// 用于设置页面中的每一行。
///
/// 设计特点：
/// - iOS 风格布局（图标 + 标题 + 副标题 + 右侧控件）
/// - 支持多种右侧控件（文字、Switch、箭头、自定义）
/// - iOS 风格交互（无水波纹，背景色渐变）
/// - 完整的样式接口
///
/// 使用示例：
/// ```dart
/// MoeSettingsRow(
///   icon: Icons.palette,
///   label: '界面设置',
///   subtitle: '主题、字体',
///   onTap: () => navigateTo(UiSettingsPage()),
/// )
/// ```
///
/// 更新记录：
/// - 2026-01-25: 添加 onLongPress 长按回调支持
/// - 2026-01-25: 添加 subtitleWidget 支持自定义副标题组件
/// - 2025-12-31: 创建设置行组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 右侧控件类型
enum MoeSettingsRowTrailing {
  /// 显示箭头（用于导航）
  chevron,
  /// 显示开关（需配合 switchValue/onSwitchChanged）
  switchControl,
  /// 显示文字（需配合 detailText）
  text,
  /// 不显示（只有点击效果）
  none,
  /// 自定义（使用 trailing 参数）
  custom,
}

/// 设置行组件
class MoeSettingsRow extends StatefulWidget {
  const MoeSettingsRow({
    super.key,
    this.icon,
    this.iconWidget,
    required this.label,
    this.labelMaxLines,
    this.subtitle,
    this.subtitleWidget,
    this.trailingType = MoeSettingsRowTrailing.chevron,
    this.trailing,
    this.detailText,
    this.switchValue,
    this.onSwitchChanged,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.showDivider = true,
    // === 样式接口 ===
    this.iconColor,
    this.labelColor,
    this.subtitleColor,
    this.backgroundColor,
    this.pressedBackgroundColor,
    this.dividerColor,
    this.iconSize = 20,
    this.iconContainerWidth = 24,
    this.contentPadding,
  });

  /// 左侧图标（可选，与 iconWidget 二选一）
  final IconData? icon;

  /// 左侧自定义组件（可选，用于 ProviderAvatar 等）
  final Widget? iconWidget;

  /// 标题
  final String label;

  /// 标题最大行数（超出省略）
  final int? labelMaxLines;

  /// 副标题（可选）
  final String? subtitle;

  /// 自定义副标题组件（可选，优先级高于 subtitle）
  final Widget? subtitleWidget;

  /// 右侧控件类型
  final MoeSettingsRowTrailing trailingType;

  /// 自定义右侧控件（trailingType 为 custom 时使用）
  final Widget? trailing;

  /// 右侧文字（trailingType 为 text 时使用）
  final String? detailText;

  /// 开关值（trailingType 为 switchControl 时使用）
  final bool? switchValue;

  /// 开关变化回调
  final ValueChanged<bool>? onSwitchChanged;

  /// 点击回调
  final VoidCallback? onTap;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 是否启用
  final bool enabled;

  /// 是否显示底部分割线
  final bool showDivider;

  // === 样式接口 ===
  
  final Color? iconColor;
  final Color? labelColor;
  final Color? subtitleColor;
  final Color? backgroundColor;
  final Color? pressedBackgroundColor;
  final Color? dividerColor;
  final double iconSize;
  final double iconContainerWidth;
  final EdgeInsets? contentPadding;

  @override
  State<MoeSettingsRow> createState() => _MoeSettingsRowState();
}

class _MoeSettingsRowState extends State<MoeSettingsRow> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && (widget.onTap != null || widget.onSwitchChanged != null);

  void _handleTap() {
    if (widget.trailingType == MoeSettingsRowTrailing.switchControl && widget.onSwitchChanged != null) {
      widget.onSwitchChanged!(!widget.switchValue!);
    } else if (widget.onTap != null) {
      widget.onTap!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析样式
    final iconColor = widget.iconColor ?? colors.text;
    final labelColor = widget.labelColor ?? colors.text;
    final subtitleColor = widget.subtitleColor ?? colors.muted;
    final bgColor = widget.backgroundColor ?? Colors.transparent;
    final pressedBg = widget.pressedBackgroundColor ?? colors.surfaceAlt.withValues(alpha: 0.5);
    final dividerColor = widget.dividerColor ?? colors.divider;
    final padding = widget.contentPadding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 11);

    final currentBg = (_pressed && _isEnabled) ? pressedBg : bgColor;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
          onTap: _isEnabled ? _handleTap : null,
          onLongPress: widget.onLongPress,
          child: AnimatedContainer(
            duration: kAnimFast,
            color: currentBg,
            padding: padding,
            child: Row(
              children: [
                // 图标区
                if (widget.icon != null || widget.iconWidget != null) ...[
                  SizedBox(
                    width: widget.iconContainerWidth,
                    child: widget.iconWidget ?? Icon(
                      widget.icon,
                      size: widget.iconSize,
                      color: widget.enabled ? iconColor : colors.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                
                // 标题区
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        maxLines: widget.labelMaxLines,
                        overflow: widget.labelMaxLines != null ? TextOverflow.ellipsis : null,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: widget.enabled ? labelColor : colors.muted,
                        ),
                      ),
                      if (widget.subtitleWidget != null) ...[                        const SizedBox(height: 2),
                        widget.subtitleWidget!,
                      ] else if (widget.subtitle != null) ...[
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
                _buildTrailing(colors),
              ],
            ),
          ),
        ),
        
        // 分割线（全宽）
        if (widget.showDivider)
          Divider(
            height: 0.5,
            thickness: 0.5,
            color: dividerColor,
          ),
      ],
    );
  }

  Widget _buildTrailing(MoeColors colors) {
    switch (widget.trailingType) {
      case MoeSettingsRowTrailing.chevron:
        return Icon(
          Icons.chevron_right,
          size: 20,
          color: colors.muted,
        );
        
      case MoeSettingsRowTrailing.switchControl:
        return IgnorePointer(
          child: Switch(
            value: widget.switchValue ?? false,
            onChanged: widget.onSwitchChanged,
            activeTrackColor: colors.focus,
            thumbColor: WidgetStateProperty.all(Colors.white),
          ),
        );
        
      case MoeSettingsRowTrailing.text:
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.detailText ?? '',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.muted,
                  ),
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.muted,
              ),
            ],
          ),
        );
        
      case MoeSettingsRowTrailing.none:
        return const SizedBox.shrink();
        
      case MoeSettingsRowTrailing.custom:
        return widget.trailing ?? const SizedBox.shrink();
    }
  }
}
