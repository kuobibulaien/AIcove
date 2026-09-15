/// MoeSecondaryButton - 次级按钮组件
///
/// 用于次要操作（取消、返回、关闭等）。
///
/// 设计特点：
/// - 跟随全局高级材质与厚度
/// - iOS 风格交互（无水波纹，颜色渐变 + 可选缩放）
/// - 支持禁用状态
/// - 完整的样式接口
///
/// 使用示例：
/// ```dart
/// MoeSecondaryButton(
///   label: '取消',
///   onPressed: () => Navigator.pop(context),
/// )
/// ```
///
/// 更新记录：
/// - 2025-12-31: 创建次级按钮组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import 'moe_button_surface.dart';

/// 次级按钮尺寸枚举
enum MoeSecondaryButtonSize { sm, md, lg }

/// 次级按钮组件
class MoeSecondaryButton extends StatefulWidget {
  const MoeSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.enabled = true,
    this.size = MoeSecondaryButtonSize.md,
    this.width,
    // === 样式接口 ===
    this.backgroundColor,
    this.foregroundColor,
    this.pressedBackgroundColor,
    this.disabledBackgroundColor,
    this.disabledForegroundColor,
    this.decoration,
    this.borderRadius,
    this.border,
    this.boxShadow,
    // === 交互配置 ===
    this.enableScale = true,
    this.pressedScale = 0.98,
  });

  /// 按钮文字
  final String label;

  /// 点击回调
  final VoidCallback? onPressed;

  /// 可选的图标
  final IconData? icon;

  /// 是否启用
  final bool enabled;

  /// 按钮尺寸
  final MoeSecondaryButtonSize size;

  /// 固定宽度
  final double? width;

  // === 样式接口 ===
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? pressedBackgroundColor;
  final Color? disabledBackgroundColor;
  final Color? disabledForegroundColor;
  final BoxDecoration? decoration;
  final BorderRadius? borderRadius;
  final BorderSide? border;
  final List<BoxShadow>? boxShadow;

  // === 交互配置 ===
  final bool enableScale;
  final double pressedScale;

  @override
  State<MoeSecondaryButton> createState() => _MoeSecondaryButtonState();
}

class _MoeSecondaryButtonState extends State<MoeSecondaryButton> {
  bool _pressed = false;

  double get _height {
    switch (widget.size) {
      case MoeSecondaryButtonSize.sm:
        return MoeButtonSizes.sm;
      case MoeSecondaryButtonSize.md:
        return MoeButtonSizes.md;
      case MoeSecondaryButtonSize.lg:
        return MoeButtonSizes.lg;
    }
  }

  double get _fontSize {
    switch (widget.size) {
      case MoeSecondaryButtonSize.sm:
        return 14;
      case MoeSecondaryButtonSize.md:
        return 16;
      case MoeSecondaryButtonSize.lg:
        return 18;
    }
  }

  EdgeInsets get _padding {
    switch (widget.size) {
      case MoeSecondaryButtonSize.sm:
        return const EdgeInsets.symmetric(horizontal: 16);
      case MoeSecondaryButtonSize.md:
        return const EdgeInsets.symmetric(horizontal: 24);
      case MoeSecondaryButtonSize.lg:
        return const EdgeInsets.symmetric(horizontal: 32);
    }
  }

  bool get _isEnabled => widget.enabled && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // Neutral buttons use the material surface; explicit semantic tints take priority.
    final bgColor = widget.backgroundColor ?? Colors.transparent;
    final fgColor = widget.foregroundColor ?? colors.text;
    final pressedBg =
        widget.pressedBackgroundColor ?? _darkenColor(bgColor, 0.08);
    final disabledBg = widget.disabledBackgroundColor ?? bgColor;
    final disabledFg = widget.disabledForegroundColor ?? colors.muted;
    final radius = widget.borderRadius ?? MoeRadii.borderSm;

    final currentBg = !_isEnabled
        ? disabledBg
        : (_pressed ? pressedBg : bgColor);
    final currentFg = !_isEnabled ? disabledFg : fgColor;

    final userDecoration = widget.decoration;
    final effectiveBorder =
        userDecoration?.border ??
        (widget.border != null ? Border.fromBorderSide(widget.border!) : null);
    final effectiveShadow = userDecoration?.boxShadow ?? widget.boxShadow;

    final scale = (widget.enableScale && _pressed && _isEnabled)
        ? widget.pressedScale
        : 1.0;

    return GestureDetector(
      onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: _isEnabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: scale,
        duration: kAnimFast,
        child: MoeButtonSurface(
          tintColor: currentBg,
          borderRadius: radius,
          border: effectiveBorder,
          shadows: effectiveShadow,
          width: widget.width,
          height: _height,
          padding: _padding,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: _fontSize + 2, color: currentFg),
                  const SizedBox(width: 8),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: _fontSize,
                    fontWeight: MoeFontWeights.emphasis,
                    color: currentFg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _darkenColor(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness(
      (hsl.lightness - amount).clamp(0.0, 1.0),
    );
    return darkened.toColor();
  }
}
