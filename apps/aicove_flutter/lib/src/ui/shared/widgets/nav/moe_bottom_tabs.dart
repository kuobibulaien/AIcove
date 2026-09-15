/// MoeBottomTabBar - 底部 Tab 切换组件
///
/// 仿 kelivo 风格的底部 Tab 切换器，支持任意数量 Tab。
///
/// 设计特点：
/// - G2 圆角边框（MoeSmoothRadii.md = 20px）
/// - 高度/宽度可配置（默认 80px / 95%）
/// - 图标+文字上下排列
/// - iOS 触觉反馈
/// - 平滑动画
///
/// 使用示例：
/// ```dart
/// MoeBottomTabBar(
///   currentIndex: _tabIndex,
///   tabs: [
///     MoeTabItem(icon: Icons.settings, label: '配置'),
///     MoeTabItem(icon: Icons.list, label: '模型'),
///   ],
///   onTap: (i) => setState(() => _tabIndex = i),
/// )
/// ```
///
/// 更新记录：
/// - 2026-01-25: 重构：高度/宽度可配置，支持任意 Tab 数量
/// - 2026-01-21: 创建底部双 Tab 组件
library;

import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_button_surface.dart';
import '../moe_floating_surface.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';

/// Tab 配置项
class MoeTabItem {
  const MoeTabItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// 底部 Tab 切换器
///
/// 支持任意数量 Tab，高度/宽度可配置。
class MoeBottomTabBar extends StatelessWidget {
  const MoeBottomTabBar({
    super.key,
    required this.currentIndex,
    required this.tabs,
    required this.onTap,
    this.height = 80,
    this.widthFactor = 0.95,
  });

  /// 当前选中索引
  final int currentIndex;

  /// Tab 配置列表
  final List<MoeTabItem> tabs;

  /// 点击回调
  final ValueChanged<int> onTap;

  /// 容器高度（默认 80，与联系人卡片一致）
  final double height;

  /// 宽度占屏幕比例（默认 0.95 即 95%）
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final dividerHeight = height * 0.6;

    return Align(
      alignment: Alignment.center,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: height,
          child: MoeFloatingSurface(
            radius: MoeSmoothRadii.md,
            solidColor: colors.componentBackground,
            shadows: MoeShadows.card,
            child: Row(
              children: List.generate(tabs.length * 2 - 1, (index) {
                if (index.isOdd) {
                  return Container(
                    width: 1,
                    height: dividerHeight,
                    color: colors.border,
                  );
                }
                final tabIndex = index ~/ 2;
                final tab = tabs[tabIndex];
                return Expanded(
                  child: _TabItem(
                    icon: tab.icon,
                    label: tab.label,
                    isSelected: currentIndex == tabIndex,
                    colors: colors,
                    onTap: () {
                      if (currentIndex != tabIndex) {
                        HapticFeedback.lightImpact();
                        onTap(tabIndex);
                      }
                    },
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final MoeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? colors.focus : colors.muted;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MoeButtonSurface(
        radius: 20,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: color,
                fontWeight: isSelected
                    ? MoeFontWeights.emphasis
                    : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部双 Tab 组件（便捷封装）
///
/// 如果只有两个 Tab，可以使用这个简化版本。
class MoeBottomTabs extends StatelessWidget {
  const MoeBottomTabs({
    super.key,
    required this.index,
    required this.leftIcon,
    required this.leftLabel,
    required this.rightIcon,
    required this.rightLabel,
    required this.onSelect,
    this.height = 80,
    this.widthFactor = 0.95,
  });

  final int index;
  final IconData leftIcon;
  final String leftLabel;
  final IconData rightIcon;
  final String rightLabel;
  final ValueChanged<int> onSelect;
  final double height;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return MoeBottomTabBar(
      currentIndex: index,
      tabs: [
        MoeTabItem(icon: leftIcon, label: leftLabel),
        MoeTabItem(icon: rightIcon, label: rightLabel),
      ],
      onTap: onSelect,
      height: height,
      widthFactor: widthFactor,
    );
  }
}
