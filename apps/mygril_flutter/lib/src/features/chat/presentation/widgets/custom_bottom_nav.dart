/// 自定义底部导航栏
/// 
/// 更新记录：
/// - 2025-12-06: 接入皮肤系统
import 'package:flutter/material.dart';
import '../../../../core/theme/skin_provider.dart';
import '../../../../core/theme/tokens.dart';

/// 自定义底部导航栏
class CustomBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<BottomNavItem> items;

  const CustomBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final itemCount = items.length;
    final skin = context.skin;
    final colors = context.moeColors;

    return Container(
      height: 64,
      decoration: skin.bottomNavDecoration(colors),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(itemCount, (index) {
          final item = items[index];
          final isSelected = index == currentIndex;
          return Expanded(
            child: _NavItem(
              icon: isSelected ? item.activeIcon : item.icon,
              label: item.label,
              isSelected: isSelected,
              onTap: () => onTap(index),
              colors: colors,
            ),
          );
        }),
      ),
    );
  }
}

/// 单个导航项
class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final MoeColors colors;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 24,
            color: isSelected ? colors.primary : colors.muted,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? colors.primary : colors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部导航项数据类
class BottomNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const BottomNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
