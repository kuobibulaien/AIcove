/// MoeIconButton - 图标按钮组件
///
/// 用于 AppBar 按钮、工具栏图标、操作图标等场景。
///
/// 设计特点：
/// - iOS 风格交互（无水波纹，颜色渐变过渡）
/// - 支持长按回调
/// - 鼠标悬停保持常态外观
/// - 最小触控区域保证（无障碍）
/// - 完整的样式接口
///
/// 使用示例：
/// ```dart
/// MoeIconButton(
///   icon: Icons.arrow_back,
///   onTap: () => Navigator.pop(context),
/// )
/// ```
///
/// 更新记录：
/// - 2025-12-31: 创建图标按钮组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import 'moe_button_surface.dart';

/// 图标按钮组件
class MoeIconButton extends StatefulWidget {
  const MoeIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.size = 22,
    this.padding = const EdgeInsets.all(8),
    this.enabled = true,
    this.semanticLabel,
    this.tooltip,
    // === 样式接口 ===
    this.color,
    this.pressedColor,
    this.hoverColor,
    this.disabledColor,
    this.backgroundColor,
    this.pressedBackgroundColor,
    this.hoverBackgroundColor,
    this.borderRadius,
    this.border,
    // === 触控配置 ===
    this.minTouchTarget = MoeButtonSizes.minTouchTarget,
  });

  /// 图标
  final IconData icon;

  /// 点击回调
  final VoidCallback? onTap;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 图标大小
  final double size;

  /// 内边距
  final EdgeInsets padding;

  /// 是否启用
  final bool enabled;

  /// 语义标签（无障碍）
  final String? semanticLabel;

  /// 语义与测试定位标签（与 semanticLabel 等效，受全局 TooltipVisibility 控制不弹出悬浮提示）
  final String? tooltip;

  // === 样式接口 ===

  /// 图标颜色（默认跟随主题文字色）
  final Color? color;

  /// 按压时的图标颜色
  final Color? pressedColor;

  /// 兼容旧调用保留；悬停不再改变图标颜色
  final Color? hoverColor;

  /// 禁用时的图标颜色
  final Color? disabledColor;

  /// 背景色（默认透明）
  final Color? backgroundColor;

  /// 按压时的背景色
  final Color? pressedBackgroundColor;

  /// 兼容旧调用保留；悬停不再改变背景色
  final Color? hoverBackgroundColor;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 边框
  final BorderSide? border;

  // === 触控配置 ===

  /// 最小触控区域
  final double minTouchTarget;

  @override
  State<MoeIconButton> createState() => _MoeIconButtonState();
}

class _MoeIconButtonState extends State<MoeIconButton> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 解析颜色：图标按钮默认无底框、无按压变色或背景反馈
    final normalColor = widget.color ?? colors.text;
    final pressedColor = widget.pressedColor ?? normalColor;
    final disabledColor = widget.disabledColor ?? colors.muted;

    final normalBg = widget.backgroundColor ?? Colors.transparent;
    final pressedBg = widget.pressedBackgroundColor ?? normalBg;

    final radius = widget.borderRadius ?? MoeRadii.borderSm;

    // 计算当前状态的颜色
    Color currentIconColor;
    Color currentBgColor;

    if (!_isEnabled) {
      currentIconColor = disabledColor;
      currentBgColor = normalBg;
    } else if (_pressed) {
      currentIconColor = pressedColor;
      currentBgColor = pressedBg;
    } else {
      currentIconColor = normalColor;
      currentBgColor = normalBg;
    }

    // 计算实际尺寸，确保满足最小触控区域
    final contentSize = widget.size + widget.padding.horizontal;
    final actualSize = contentSize < widget.minTouchTarget
        ? widget.minTouchTarget
        : contentSize;

    final hasSurface =
        widget.backgroundColor != null ||
        widget.pressedBackgroundColor != null ||
        widget.border != null;

    final iconChild = Center(
      child: TweenAnimationBuilder<Color?>(
        duration: kAnimFast,
        tween: ColorTween(end: currentIconColor),
        builder: (context, animatedColor, _) => Icon(
          widget.icon,
          size: widget.size,
          color: animatedColor ?? currentIconColor,
        ),
      ),
    );

    Widget button = MouseRegion(
      cursor: _isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
        onTap: _isEnabled ? widget.onTap : null,
        onLongPress: _isEnabled ? widget.onLongPress : null,
        onSecondaryTapUp: (_isEnabled && widget.onLongPress != null)
            ? (_) => widget.onLongPress!()
            : null,
        behavior: HitTestBehavior.opaque,
        child: hasSurface
            ? MoeButtonSurface(
                shareParentSurface: false,
                tintColor: currentBgColor,
                borderRadius: radius,
                border: widget.border == null
                    ? null
                    : Border.fromBorderSide(widget.border!),
                width: actualSize,
                height: actualSize,
                child: iconChild,
              )
            : SizedBox(
                width: actualSize,
                height: actualSize,
                child: iconChild,
              ),
      ),
    );

    // 添加语义支持
    final label = widget.semanticLabel ?? widget.tooltip;
    if (label != null) {
      button = TooltipVisibility(
        visible: false,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            enabled: _isEnabled,
            label: label,
            child: button,
          ),
        ),
      );
    }

    return button;
  }
}
