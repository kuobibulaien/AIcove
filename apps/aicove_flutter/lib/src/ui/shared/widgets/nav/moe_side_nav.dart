import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 侧边导航项数据类
class SideNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String? label;
  final String? tooltip;

  const SideNavItem({
    required this.icon,
    required this.activeIcon,
    this.label,
    this.tooltip,
  });
}

/// 垂直侧边导航栏（类似QQ/微信桌面端）
///
/// 布局结构：
/// - 上方：主要导航项（消息、角色卡、我的）
/// - 下方：设置按钮
class MoeSideNav extends StatelessWidget {
  /// 当前选中索引
  final int currentIndex;

  /// 切换回调
  final ValueChanged<int> onTap;

  /// 导航项列表
  final List<SideNavItem> items;

  /// 设置按钮点击回调
  final VoidCallback? onSettingsTap;

  /// 导航栏宽度
  final double width;

  const MoeSideNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    this.onSettingsTap,
    this.width = 64,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          right: BorderSide(color: colors.divider, width: borderWidth),
        ),
      ),
      child: Column(
        children: [
          // 顶部间距（与AppBar对齐）
          const SizedBox(height: 12),

          // 主要导航项
          ...List.generate(items.length, (index) {
            final item = items[index];
            final isSelected = index == currentIndex;
            return _SideNavItem(
              icon: isSelected ? item.activeIcon : item.icon,
              label: item.label,
              tooltip: item.tooltip ?? item.label,
              isSelected: isSelected,
              onTap: () => onTap(index),
              colors: colors,
            );
          }),

          // 弹性空间
          const Spacer(),

          // 设置按钮（底部）
          if (onSettingsTap != null)
            _SideNavItem(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              isSelected: false,
              onTap: onSettingsTap!,
              colors: colors,
            ),

          // 底部安全间距
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 单个侧边导航项
class _SideNavItem extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool isSelected;
  final VoidCallback onTap;
  final MoeColors colors;

  const _SideNavItem({
    required this.icon,
    this.label,
    this.tooltip,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      preferBelow: false,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 选中指示器 + 图标
              Container(
                width: 44,
                height: 32,
                decoration: isSelected
                    ? BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      )
                    : null,
                child: Icon(
                  icon,
                  size: 24,
                  color: isSelected ? colors.primary : colors.muted,
                ),
              ),
              // 标签文字（可选）
              if (label != null) ...[
                const SizedBox(height: 2),
                Text(
                  label!,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
                    color: isSelected ? colors.primary : colors.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
