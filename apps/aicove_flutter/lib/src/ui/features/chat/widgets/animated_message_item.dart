/// 消息出现动画组件
///
/// 从 chat_page.dart 提取，用于让新消息以轻量方式平滑出现。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-02-27: 移除侧边滑入与淡入动画，改为直接显示
/// - 2026-03-23: 恢复轻量入场动画，避免新消息硬切
library;

import 'package:flutter/material.dart';

class AnimatedMessageItem extends StatefulWidget {
  final Widget child;

  /// 入场动画结束（完成，或未完成即被回收）时回调一次。
  /// 列表用它结束 metricsReanchor 的入场静默——入场期的 extent 增长是
  /// 结构性来源，须以动画生命周期事实为准，不能用帧时间戳猜时长
  /// （warm-up 帧跳变、timeDilation、长帧都会失真）。
  final VoidCallback? onFinished;

  const AnimatedMessageItem({
    super.key,
    required this.child,
    this.onFinished,
  });

  /// 入场动画时长。
  static const Duration kDuration = Duration(milliseconds: 220);

  @override
  State<AnimatedMessageItem> createState() => _AnimatedMessageItemState();
}

class _AnimatedMessageItemState extends State<AnimatedMessageItem>
    with SingleTickerProviderStateMixin {
  bool _notifiedFinished = false;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AnimatedMessageItem.kDuration,
  )
    ..addStatusListener(_handleAnimationStatus)
    ..forward();
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _fadeAnimation = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.0, 0.8, curve: Curves.easeOut),
  );
  late final Animation<Offset> _slideAnimation = Tween<Offset>(
    begin: const Offset(0, 0.05),
    end: Offset.zero,
  ).animate(_curve);

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _notifyFinished();
    }
  }

  void _notifyFinished() {
    if (_notifiedFinished) return;
    _notifiedFinished = true;
    widget.onFinished?.call();
  }

  @override
  void dispose() {
    _notifyFinished();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SizeTransition(
        sizeFactor: _curve,
        axisAlignment: 1.0,
        child: SlideTransition(
          position: _slideAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}
