/// MoeToast - 可换肤的轻量级提示组件
/// 
/// 使用 Overlay 实现自定义 Toast，支持：
/// - 屏幕中央显示
/// - 淡入淡出动画
/// - 图标支持
/// - 皮肤系统集成
/// 
/// 更新记录：
/// - 2025-12-06: 创建，统一全局提示样式
/// - 2025-12-06: 重构为 Overlay 实现，增加动画和图标
/// - 2025-12-06: 接入皮肤系统
import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/skin_provider.dart';

/// Toast 类型枚举
enum ToastType { info, success, error, warning }

/// 轻量级 Toast 提示工具
class MoeToast {
  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  /// 显示 Toast（核心方法）
  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 2),
    IconData? icon,
  }) {
    // 移除当前的 Toast
    _dismiss();

    final overlay = Overlay.of(context);
    
    _currentEntry = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        type: type,
        icon: icon,
        onDismiss: _dismiss,
      ),
    );

    overlay.insert(_currentEntry!);

    _timer = Timer(duration, _dismiss);
  }

  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }

  /// 普通提示
  static void info(BuildContext context, String message) {
    show(context, message, type: ToastType.info);
  }

  /// 成功提示
  static void success(BuildContext context, String message) {
    show(context, message, type: ToastType.success, icon: Icons.check_circle_outline);
  }

  /// 错误提示
  static void error(BuildContext context, String message) {
    show(context, message, type: ToastType.error, icon: Icons.error_outline, duration: const Duration(seconds: 3));
  }

  /// 警告提示
  static void warning(BuildContext context, String message) {
    show(context, message, type: ToastType.warning, icon: Icons.warning_amber_outlined);
  }

  /// 短暂提示（1.5秒，常用于操作反馈）
  static void brief(BuildContext context, String message) {
    show(context, message, duration: const Duration(milliseconds: 1500));
  }
}

/// Toast 显示组件（内部使用）
class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final IconData? icon;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.type,
    required this.onDismiss,
    this.icon,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _getBackgroundColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    switch (widget.type) {
      case ToastType.success:
        return isDark ? const Color(0xFF1B5E20) : const Color(0xFF4CAF50);
      case ToastType.error:
        return isDark ? const Color(0xFFB71C1C) : const Color(0xFFE53935);
      case ToastType.warning:
        return isDark ? const Color(0xFFE65100) : const Color(0xFFFF9800);
      case ToastType.info:
      default:
        return isDark ? const Color(0xFF37474F) : const Color(0xFF424242);
    }
  }

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final bgColor = _getBackgroundColor(context);
    final decoration = skin.toastDecoration(bgColor);

    return Positioned(
      top: MediaQuery.of(context).size.height * 0.15,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.8,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: decoration,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null) ...[
                      Icon(widget.icon, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
