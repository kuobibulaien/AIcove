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
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 分段选择器组件
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
    final colors = context.moeColors;

    final content = Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: MoeG2Decoration(
        radius: 18,
        color: colors.surface,
        border: Border.all(color: colors.border, width: 1),
      ),
      child: Row(
        mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
        children: List.generate(tabs.length, (index) {
          final isSelected = currentIndex == index;
          return scrollable
              ? _buildTab(context, index, isSelected, colors)
              : Expanded(child: _buildTab(context, index, isSelected, colors));
        }),
      ),
    );

    if (scrollable) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: content,
      );
    }

    return content;
  }

  Widget _buildTab(BuildContext context, int index, bool isSelected, MoeColors colors) {
    return GestureDetector(
      onTap: () {
        if (currentIndex != index) {
          HapticFeedback.lightImpact();
          onTap(index);
        }
      },
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: MoeG2Decoration(
          radius: 15,
          color: isSelected ? colors.focus : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: Text(
          tabs[index],
          style: TextStyle(
            fontSize: 13,
            color: isSelected ? Colors.white : colors.textSecondary,
            fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
          ),
        ),
      ),
    );
  }
}

/// 带图标的分段选择器
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
    final colors = context.moeColors;

    final content = Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: MoeG2Decoration(
        radius: 20,
        color: colors.surface,
        border: Border.all(color: colors.border, width: 1),
      ),
      child: Row(
        mainAxisSize: scrollable ? MainAxisSize.min : MainAxisSize.max,
        children: List.generate(tabs.length, (index) {
          final isSelected = currentIndex == index;
          final tab = tabs[index];
          return scrollable
              ? _buildTab(context, index, tab, isSelected, colors)
              : Expanded(child: _buildTab(context, index, tab, isSelected, colors));
        }),
      ),
    );

    if (scrollable) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: content,
      );
    }

    return content;
  }

  Widget _buildTab(
    BuildContext context,
    int index,
    MoeSegTabItem tab,
    bool isSelected,
    MoeColors colors,
  ) {
    return GestureDetector(
      onTap: () {
        if (currentIndex != index) {
          HapticFeedback.lightImpact();
          onTap(index);
        }
      },
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: MoeG2Decoration(
          radius: 17,
          color: isSelected ? colors.focus : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 16,
              color: isSelected ? Colors.white : colors.muted,
            ),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 13,
                color: isSelected ? Colors.white : colors.textSecondary,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分段 Tab 配置项
class MoeSegTabItem {
  const MoeSegTabItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}
