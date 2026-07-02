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
library;
import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import '../../theme/skin_provider.dart';
import '../effects/smooth_clip.dart';

/// Toast 类型枚举
enum ToastType { info, success, error, warning }

/// 根据 Toast 类型从主题中获取背景色（统一入口，DRY）
Color _toastBackgroundColor(BuildContext context, ToastType type) {
  final colors = context.moeColors;
  switch (type) {
    case ToastType.success:
      return colors.toastSuccess;
    case ToastType.error:
      return colors.toastError;
    case ToastType.warning:
      return colors.toastWarning;
    case ToastType.info:
      return colors.toastInfo;
  }
}

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
    show(context, message, duration: kDurationToast);
  }

  /// 可静默通知
  /// 
  /// 显示带"不再提醒"按钮的 Toast。
  /// 
  /// [noticeKey] 用于标识此类通知的唯一键名
  /// [onDismissForever] 用户点击"不再提醒"时的回调
  static void showDismissible(
    BuildContext context,
    String message, {
    required String noticeKey,
    required Future<void> Function() onDismissForever,
    ToastType type = ToastType.warning,
    Duration duration = const Duration(seconds: 4),
  }) {
    // 移除当前的 Toast
    _dismiss();

    final overlay = Overlay.of(context);
    
    _currentEntry = OverlayEntry(
      builder: (context) => _DismissibleToastWidget(
        message: message,
        type: type,
        onDismiss: _dismiss,
        onDismissForever: () async {
          await onDismissForever();
          _dismiss();
        },
      ),
    );

    overlay.insert(_currentEntry!);

    _timer = Timer(duration, _dismiss);
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
      duration: kAnim,
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

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final bgColor = _toastBackgroundColor(context, widget.type);
    final decoration = skin.toastDecoration(bgColor);

    return Positioned(
      top: MediaQuery.sizeOf(context).height * 0.15,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Material(
              color: Colors.transparent,
              child: MoeG2ClipRRect(
                radius: MoeSmoothRadii.sm,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.8,
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
                            fontWeight: MoeFontWeights.emphasis,
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
      ),
    );
  }
}

/// 可静默 Toast 组件（内部使用）
class _DismissibleToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final VoidCallback onDismiss;
  final Future<void> Function() onDismissForever;

  const _DismissibleToastWidget({
    required this.message,
    required this.type,
    required this.onDismiss,
    required this.onDismissForever,
  });

  @override
  State<_DismissibleToastWidget> createState() => _DismissibleToastWidgetState();
}

class _DismissibleToastWidgetState extends State<_DismissibleToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kAnim,
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

  @override
  Widget build(BuildContext context) {
    final skin = context.skin;
    final bgColor = _toastBackgroundColor(context, widget.type);
    final decoration = skin.toastDecoration(bgColor);

    return Positioned(
      top: MediaQuery.sizeOf(context).height * 0.15,
      left: 0,
      right: 0,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Material(
              color: Colors.transparent,
              child: MoeG2ClipRRect(
                radius: MoeSmoothRadii.sm,
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.85,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: decoration,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning_amber_outlined, color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              widget.message,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: MoeFontWeights.emphasis,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: widget.onDismiss,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: MoeG2Decoration(
                                radius: 16,
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                              child: const Text(
                                '知道了',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: MoeFontWeights.emphasis,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: widget.onDismissForever,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: MoeG2Decoration(
                                radius: 16,
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                              child: const Text(
                                '不再提醒',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: MoeFontWeights.emphasis,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
