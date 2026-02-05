/// MoeSwitch - 统一开关组件
/// 
/// iOS 风格的开关控件。
/// 
/// 设计特点：
/// - 仿 iOS 原生开关外观
/// - 流畅的动画过渡
/// - 可选的触觉反馈
/// - 完整的样式接口
/// 
/// 使用示例：
/// ```dart
/// MoeSwitch(
///   value: _enabled,
///   onChanged: (v) => setState(() => _enabled = v),
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建统一开关组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 开关尺寸枚举
enum MoeSwitchSize { sm, md }

/// 统一开关组件
class MoeSwitch extends StatefulWidget {
  const MoeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = MoeSwitchSize.md,
    this.enabled = true,
    this.enableHaptics = true,
    this.semanticLabel,
    // === 样式接口 ===
    this.activeColor,
    this.activeTrackColor,
    this.inactiveColor,
    this.inactiveTrackColor,
    this.thumbColor,
    this.disabledThumbColor,
    this.borderRadius,
  });

  /// 当前值
  final bool value;

  /// 值变化回调
  final ValueChanged<bool>? onChanged;

  /// 开关尺寸
  final MoeSwitchSize size;

  /// 是否启用
  final bool enabled;

  /// 是否启用触觉反馈
  final bool enableHaptics;

  /// 语义标签
  final String? semanticLabel;

  // === 样式接口 ===
  
  /// 开启时的强调色（滑块颜色，如果未指定则用主题色）
  final Color? activeColor;

  /// 开启时的轨道颜色
  final Color? activeTrackColor;

  /// 关闭时的强调色（滑块颜色）
  final Color? inactiveColor;

  /// 关闭时的轨道颜色
  final Color? inactiveTrackColor;

  /// 滑块颜色（覆盖 activeColor/inactiveColor）
  final Color? thumbColor;

  /// 禁用时的滑块颜色
  final Color? disabledThumbColor;

  /// 轨道圆角
  final BorderRadius? borderRadius;

  @override
  State<MoeSwitch> createState() => _MoeSwitchState();
}

class _MoeSwitchState extends State<MoeSwitch> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && widget.onChanged != null;

  // 尺寸配置
  double get _width {
    switch (widget.size) {
      case MoeSwitchSize.sm:
        return 40;
      case MoeSwitchSize.md:
        return 50;
    }
  }

  double get _height {
    switch (widget.size) {
      case MoeSwitchSize.sm:
        return 24;
      case MoeSwitchSize.md:
        return 30;
    }
  }

  double get _thumbSize {
    switch (widget.size) {
      case MoeSwitchSize.sm:
        return 20;
      case MoeSwitchSize.md:
        return 26;
    }
  }

  double get _thumbPadding {
    switch (widget.size) {
      case MoeSwitchSize.sm:
        return 2;
      case MoeSwitchSize.md:
        return 2;
    }
  }

  void _handleTap() {
    if (!_isEnabled) return;
    
    if (widget.enableHaptics) {
      HapticFeedback.lightImpact();
    }
    
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析颜色
    final activeTrack = widget.activeTrackColor ?? colors.focus;
    final inactiveTrack = widget.inactiveTrackColor ?? colors.surfaceAlt;
    final activeThumb = widget.thumbColor ?? widget.activeColor ?? Colors.white;
    final inactiveThumb = widget.thumbColor ?? widget.inactiveColor ?? Colors.white;
    final disabledThumb = widget.disabledThumbColor ?? colors.muted;
    
    final radius = widget.borderRadius?.topLeft.x ?? (_height / 2);

    // 计算当前状态
    final trackColor = !_isEnabled
        ? inactiveTrack.withValues(alpha: 0.5)
        : (widget.value ? activeTrack : inactiveTrack);
    
    final thumbColor = !_isEnabled
        ? disabledThumb
        : (widget.value ? activeThumb : inactiveThumb);

    // 缩放效果
    final scale = (_pressed && _isEnabled) ? 0.95 : 1.0;

    Widget switchWidget = GestureDetector(
      onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: _handleTap,
      child: AnimatedScale(
        scale: scale,
        duration: kAnimFast,
        child: AnimatedContainer(
          duration: kAnim,
          width: _width,
          height: _height,
          decoration: MoeG2Decoration(
            radius: radius,
            color: trackColor,
          ),
          child: AnimatedAlign(
            duration: kAnim,
            curve: Curves.easeOutCubic,
            alignment: widget.value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: _thumbSize,
              height: _thumbSize,
              margin: EdgeInsets.all(_thumbPadding),
              decoration: BoxDecoration(
                color: thumbColor,
                shape: BoxShape.circle,
                boxShadow: MoeShadows.soft,
              ),
            ),
          ),
        ),
      ),
    );

    // 添加语义支持
    if (widget.semanticLabel != null) {
      switchWidget = Semantics(
        toggled: widget.value,
        enabled: _isEnabled,
        label: widget.semanticLabel,
        child: switchWidget,
      );
    }

    return switchWidget;
  }
}
