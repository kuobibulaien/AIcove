/// 消息出现动画组件
///
/// 从 chat_page.dart 提取。当前为“无入场动画”实现：新消息直接出现。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-02-27: 移除侧边滑入与淡入动画，改为直接显示
library;

import 'package:flutter/material.dart';

/// 消息包装组件（保留原组件名，避免影响调用方）
/// 当前不执行任何动画，直接返回子组件。
class AnimatedMessageItem extends StatelessWidget {
  final Widget child;

  const AnimatedMessageItem({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}
