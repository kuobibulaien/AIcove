/// MoePrimaryButton - 主按钮组件
///
/// 用于主要操作（确认、提交、保存等）。
///
/// 设计特点：
/// - 高级材质叠加轻量主题强调色
/// - iOS 风格交互（无水波纹，颜色渐变 + 可选缩放）
/// - 支持加载状态、禁用状态
/// - 完整的样式接口（颜色、装饰、边框、圆角、阴影皆可覆盖）
///
/// 使用示例：
/// ```dart
/// MoePrimaryButton(
///   label: '确认',
///   onPressed: () => doSomething(),
/// )
/// ```
///
/// 更新记录：
/// - 2025-12-31: 创建主按钮组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import 'moe_button_surface.dart';

/// 主按钮尺寸枚举
enum MoePrimaryButtonSize { sm, md, lg }

/// 主按钮组件
class MoePrimaryButton extends StatefulWidget {
  const MoePrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.enabled = true,
    this.size = MoePrimaryButtonSize.md,
    this.width,
    // === 样式接口（为 null 时使用主题默认值）===
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

  /// 可选的图标（显示在文字左侧）
  final IconData? icon;

  /// 是否处于加载状态
  final bool isLoading;

  /// 是否启用
  final bool enabled;

  /// 按钮尺寸
  final MoePrimaryButtonSize size;

  /// 固定宽度（为 null 时自适应内容）
  final double? width;

  // === 样式接口 ===

  /// 材质染色（默认 = colors.accentColor）
  final Color? backgroundColor;

  /// 前景色/文字色（默认 = colors.text）
  final Color? foregroundColor;

  /// 按压时的背景色
  final Color? pressedBackgroundColor;

  /// 禁用时的背景色
  final Color? disabledBackgroundColor;

  /// 禁用时的前景色
  final Color? disabledForegroundColor;

  /// 完整的装饰（会覆盖其他样式参数）
  final BoxDecoration? decoration;

  /// 圆角（默认 = MoeRadii.sm）
  final BorderRadius? borderRadius;

  /// 边框
  final BorderSide? border;

  /// 阴影
  final List<BoxShadow>? boxShadow;

  // === 交互配置 ===

  /// 是否启用按压缩放效果
  final bool enableScale;

  /// 按压时的缩放比例
  final double pressedScale;

  @override
  State<MoePrimaryButton> createState() => _MoePrimaryButtonState();
}

class _MoePrimaryButtonState extends State<MoePrimaryButton> {
  bool _pressed = false;

  double get _height {
    switch (widget.size) {
      case MoePrimaryButtonSize.sm:
        return MoeButtonSizes.sm;
      case MoePrimaryButtonSize.md:
        return MoeButtonSizes.md;
      case MoePrimaryButtonSize.lg:
        return MoeButtonSizes.lg;
    }
  }

  double get _fontSize {
    switch (widget.size) {
      case MoePrimaryButtonSize.sm:
        return 14;
      case MoePrimaryButtonSize.md:
        return 16;
      case MoePrimaryButtonSize.lg:
        return 18;
    }
  }

  EdgeInsets get _padding {
    switch (widget.size) {
      case MoePrimaryButtonSize.sm:
        return const EdgeInsets.symmetric(horizontal: 16);
      case MoePrimaryButtonSize.md:
        return const EdgeInsets.symmetric(horizontal: 24);
      case MoePrimaryButtonSize.lg:
        return const EdgeInsets.symmetric(horizontal: 32);
    }
  }

  bool get _isEnabled =>
      widget.enabled && !widget.isLoading && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    // 解析样式（优先使用传入值，否则使用主题默认值）
    // 主按钮使用 accentColor 作为默认背景色，与 AppBar 一致
    final bgColor = widget.backgroundColor ?? colors.accentColor;
    // Translucent accents use the theme text color for readable labels.
    final fgColor = widget.foregroundColor ?? colors.text;
    final pressedBg =
        widget.pressedBackgroundColor ?? _darkenColor(bgColor, 0.1);
    final disabledBg = widget.disabledBackgroundColor ?? colors.surfaceAlt;
    final disabledFg = widget.disabledForegroundColor ?? colors.muted;
    final radius = widget.borderRadius ?? MoeRadii.borderSm;
    final shadow = widget.boxShadow;

    // 计算当前状态的颜色
    final currentBg = !_isEnabled
        ? disabledBg
        : (_pressed ? pressedBg : bgColor);
    final currentFg = !_isEnabled ? disabledFg : fgColor;

    // 构建装饰
    final userDecoration = widget.decoration;
    final effectiveBorder =
        userDecoration?.border ??
        (widget.border != null ? Border.fromBorderSide(widget.border!) : null);
    final effectiveShadow =
        userDecoration?.boxShadow ?? (_isEnabled ? shadow : null);

    // 计算缩放
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
            child: widget.isLoading
                ? SizedBox(
                    width: _fontSize + 4,
                    height: _fontSize + 4,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(currentFg),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(
                          widget.icon,
                          size: _fontSize + 2,
                          color: currentFg,
                        ),
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

  /// 将颜色加深指定比例
  Color _darkenColor(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final darkened = hsl.withLightness(
      (hsl.lightness - amount).clamp(0.0, 1.0),
    );
    return darkened.toColor();
  }
}
