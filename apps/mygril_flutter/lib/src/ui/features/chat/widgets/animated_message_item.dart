/// 消息出现动画组件
/// 
/// 从 chat_page.dart 提取，实现消息滑入动画效果。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
library;

import 'package:flutter/material.dart';

/// 带有出现动画的消息包装组件
/// 实现从屏幕边缘滑入的效果（用户消息从右边，AI消息从左边）
class AnimatedMessageItem extends StatefulWidget {
  final Widget child;
  final bool isMe; // 是否是用户消息（决定动画方向）

  const AnimatedMessageItem({
    super.key,
    required this.child,
    required this.isMe,
  });

  @override
  State<AnimatedMessageItem> createState() => _AnimatedMessageItemState();
}

class _AnimatedMessageItemState extends State<AnimatedMessageItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    
    // 创建动画控制器（400ms）
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // 淡入动画：从 0.3 到 1
    _opacityAnimation = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // 滑动动画：根据消息来源决定方向
    final startOffset = widget.isMe 
        ? const Offset(1.0, 0.0)  // 从右边滑入
        : const Offset(-1.0, 0.0); // 从左边滑入
    
    _slideAnimation = Tween<Offset>(
      begin: startOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // 启动动画
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacityAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: widget.child,
      ),
    );
  }
}
