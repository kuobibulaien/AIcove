/// MoeSegTabBar - 分段选择器组件
///
/// 仿 kelivo 风格的水平分段选择器。
///
/// 设计特点：
/// - 水平滚动 + 选中高亮
/// - iOS 触觉反馈
/// - 平滑动画
/// - 圆角胶囊形状
///
/// 使用示例：
/// ```dart
/// MoeSegTabBar(
///   currentIndex: _index,
///   tabs: ['OpenAI', 'Claude', 'Gemini'],
///   onTap: (index) => setState(() => _index = index),
/// )
/// ```
///
/// 更新记录：
/// - 2026-01-21: 创建分段选择器组件
library;

import 'package:flutter/material.dart';
import '../form/moe_toggle_bar.dart';

/// 分段选择器组件（底层统一复用 [MoeToggleBar]）
class MoeSegTabBar extends StatelessWidget {
  const MoeSegTabBar({
    super.key,
    required this.currentIndex,
    required this.tabs,
    required this.onTap,
    this.scrollable = false,
  });

  /// 当前选中索引
  final int currentIndex;

  /// Tab 标签列表
  final List<String> tabs;

  /// 点击回调
  final ValueChanged<int> onTap;

  /// 是否可滚动
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final bar = MoeToggleBar<int>(
      value: currentIndex,
      expanded: !scrollable,
      items: [
        for (var i = 0; i < tabs.length; i++)
          MoeToggleItem<int>(value: i, label: tabs[i]),
      ],
      onChanged: onTap,
    );
    if (!scrollable) return bar;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: bar,
    );
  }
}

/// 带图标的分段选择器（底层统一复用 [MoeToggleBar]）
class MoeSegTabBarWithIcon extends StatelessWidget {
  const MoeSegTabBarWithIcon({
    super.key,
    required this.currentIndex,
    required this.tabs,
    required this.onTap,
    this.scrollable = false,
  });

  /// 当前选中索引
  final int currentIndex;

  /// Tab 配置列表
  final List<MoeSegTabItem> tabs;

  /// 点击回调
  final ValueChanged<int> onTap;

  /// 是否可滚动
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final bar = MoeToggleBar<int>(
      value: currentIndex,
      expanded: !scrollable,
      items: [
        for (var i = 0; i < tabs.length; i++)
          MoeToggleItem<int>(
            value: i,
            label: tabs[i].label,
            icon: tabs[i].icon,
          ),
      ],
      onChanged: onTap,
    );
    if (!scrollable) return bar;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: bar,
    );
  }
}

/// 分段 Tab 配置项
class MoeSegTabItem {
  const MoeSegTabItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}
