/// MoeCheckbox - 统一复选框组件
/// 
/// iOS 风格的圆形复选框。
/// 
/// 设计特点：
/// - 圆形外观
/// - 勾选动画
/// - 触觉反馈
/// - 完整的样式接口
/// 
/// 使用示例：
/// ```dart
/// MoeCheckbox(
///   value: _checked,
///   onChanged: (v) => setState(() => _checked = v),
///   label: '同意条款',
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建复选框组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';

/// 复选框尺寸枚举
enum MoeCheckboxSize { sm, md }

/// 统一复选框组件
class MoeCheckbox extends StatefulWidget {
  const MoeCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.size = MoeCheckboxSize.md,
    this.label,
    this.enabled = true,
    this.enableHaptics = true,
    // === 样式接口 ===
    this.activeColor,
    this.inactiveColor,
    this.checkColor,
    this.borderColor,
    this.borderWidth,
  });

  /// 当前值
  final bool value;

  /// 值变化回调
  final ValueChanged<bool>? onChanged;

  /// 复选框尺寸
  final MoeCheckboxSize size;

  /// 可选文字标签
  final String? label;

  /// 是否启用
  final bool enabled;

  /// 是否启用触觉反馈
  final bool enableHaptics;

  // === 样式接口 ===
  
  /// 选中时的填充色
  final Color? activeColor;

  /// 未选中时的填充色
  final Color? inactiveColor;

  /// 勾选符号颜色
  final Color? checkColor;

  /// 边框颜色
  final Color? borderColor;

  /// 边框宽度
  final double? borderWidth;

  @override
  State<MoeCheckbox> createState() => _MoeCheckboxState();
}

class _MoeCheckboxState extends State<MoeCheckbox> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _checkAnimation;

  bool get _isEnabled => widget.enabled && widget.onChanged != null;

  double get _size {
    switch (widget.size) {
      case MoeCheckboxSize.sm:
        return 18;
      case MoeCheckboxSize.md:
        return 22;
    }
  }

  double get _hitTestSize {
    switch (widget.size) {
      case MoeCheckboxSize.sm:
        return 32;
      case MoeCheckboxSize.md:
        return 40;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: kAnimFast,
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _checkAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    
    if (widget.value) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(MoeCheckbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
    
    // 解析样式
    final activeColor = widget.activeColor ?? colors.focus;
    final inactiveColor = widget.inactiveColor ?? Colors.transparent;
    final checkColor = widget.checkColor ?? Colors.white;
    final borderColor = widget.borderColor ?? colors.border;
    final borderWidth = widget.borderWidth ?? 1.5;

    final checkbox = GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: _hitTestSize,
        height: _hitTestSize,
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Transform.scale(
                scale: widget.value ? _scaleAnimation.value : 1.0,
                child: Container(
                  width: _size,
                  height: _size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.value 
                        ? (_isEnabled ? activeColor : colors.muted) 
                        : inactiveColor,
                    border: Border.all(
                      color: widget.value 
                          ? (_isEnabled ? activeColor : colors.muted)
                          : (_isEnabled ? borderColor : colors.muted),
                      width: borderWidth,
                    ),
                  ),
                  child: widget.value
                      ? CustomPaint(
                          painter: _CheckPainter(
                            color: checkColor,
                            progress: _checkAnimation.value,
                          ),
                        )
                      : null,
                ),
              );
            },
          ),
        ),
      ),
    );

    // 如果有标签，包装成可点击的行
    if (widget.label != null) {
      return GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            checkbox,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.label!,
                style: TextStyle(
                  fontSize: 14,
                  color: _isEnabled ? colors.text : colors.muted,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return checkbox;
  }
}

/// 勾选符号绘制器
class _CheckPainter extends CustomPainter {
  final Color color;
  final double progress;

  _CheckPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    
    // 勾选路径
    final startX = centerX - size.width * 0.2;
    final startY = centerY;
    final midX = centerX - size.width * 0.05;
    final midY = centerY + size.height * 0.15;
    final endX = centerX + size.width * 0.25;
    final endY = centerY - size.height * 0.15;

    path.moveTo(startX, startY);
    
    if (progress <= 0.5) {
      // 第一段
      final t = progress * 2;
      final x = startX + (midX - startX) * t;
      final y = startY + (midY - startY) * t;
      path.lineTo(x, y);
    } else {
      // 第一段 + 第二段
      path.lineTo(midX, midY);
      final t = (progress - 0.5) * 2;
      final x = midX + (endX - midX) * t;
      final y = midY + (endY - midY) * t;
      path.lineTo(x, y);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
