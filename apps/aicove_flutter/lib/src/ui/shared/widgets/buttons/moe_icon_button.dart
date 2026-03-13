/// MoeIconButton - 图标按钮组件
/// 
/// 用于 AppBar 按钮、工具栏图标、操作图标等场景。
/// 
/// 设计特点：
/// - iOS 风格交互（无水波纹，颜色渐变过渡）
/// - 支持长按回调
/// - 支持 Hover 状态（桌面端）
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
import '../../effects/smooth_clip.dart';

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

  // === 样式接口 ===
  
  /// 图标颜色（默认跟随主题文字色）
  final Color? color;

  /// 按压时的图标颜色
  final Color? pressedColor;

  /// Hover 时的图标颜色
  final Color? hoverColor;

  /// 禁用时的图标颜色
  final Color? disabledColor;

  /// 背景色（默认透明）
  final Color? backgroundColor;

  /// 按压时的背景色
  final Color? pressedBackgroundColor;

  /// Hover 时的背景色
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
  bool _hovered = false;

  bool get _isEnabled => widget.enabled && widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析颜色
    final normalColor = widget.color ?? colors.text;
    final pressedColor = widget.pressedColor ?? normalColor.withValues(alpha: 0.6);
    final hoverColor = widget.hoverColor ?? normalColor;
    final disabledColor = widget.disabledColor ?? colors.muted;
    
    final normalBg = widget.backgroundColor ?? Colors.transparent;
    final pressedBg = widget.pressedBackgroundColor ?? colors.surfaceAlt.withValues(alpha: 0.5);
    final hoverBg = widget.hoverBackgroundColor ?? colors.surfaceAlt.withValues(alpha: 0.3);
    
    final radius = widget.borderRadius ?? MoeRadii.borderSm;
    final g2Radius = radius.topLeft.x;

    // 计算当前状态的颜色
    Color currentIconColor;
    Color currentBgColor;
    
    if (!_isEnabled) {
      currentIconColor = disabledColor;
      currentBgColor = normalBg;
    } else if (_pressed) {
      currentIconColor = pressedColor;
      currentBgColor = pressedBg;
    } else if (_hovered) {
      currentIconColor = hoverColor;
      currentBgColor = hoverBg;
    } else {
      currentIconColor = normalColor;
      currentBgColor = normalBg;
    }

    // 计算实际尺寸，确保满足最小触控区域
    final contentSize = widget.size + widget.padding.horizontal;
    final actualSize = contentSize < widget.minTouchTarget 
        ? widget.minTouchTarget 
        : contentSize;

    Widget button = MouseRegion(
      onEnter: _isEnabled ? (_) => setState(() => _hovered = true) : null,
      onExit: _isEnabled ? (_) => setState(() => _hovered = false) : null,
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
        child: AnimatedContainer(
          duration: kAnimFast,
          width: actualSize,
          height: actualSize,
          decoration: MoeG2Decoration(
            radius: g2Radius,
            color: currentBgColor,
            border: widget.border != null ? Border.fromBorderSide(widget.border!) : null,
          ),
          child: Center(
            child: TweenAnimationBuilder<Color?>(
              duration: kAnimFast,
              tween: ColorTween(end: currentIconColor),
              builder: (context, animatedColor, _) => Icon(
                widget.icon,
                size: widget.size,
                color: animatedColor ?? currentIconColor,
              ),
            ),
          ),
        ),
      ),
    );

    // 添加语义支持
    if (widget.semanticLabel != null) {
      button = Semantics(
        button: true,
        enabled: _isEnabled,
        label: widget.semanticLabel,
        child: button,
      );
    }

    return button;
  }
}
