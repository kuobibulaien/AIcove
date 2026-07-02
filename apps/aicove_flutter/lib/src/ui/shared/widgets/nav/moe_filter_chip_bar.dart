/// MoeFilterChipBar - 水平滚动筛选标签栏
/// 
/// 用于在多个选项间切换，如分类筛选、Tab 切换等。
/// 
/// 设计特点：
/// - 水平滚动
/// - 选中项高亮
/// - 可选的计数徽章
/// - iOS 风格无水波纹交互
/// 
/// 使用示例：
/// ```dart
/// MoeFilterChipBar<String>(
///   items: ['聊天', '绘图', '语音'],
///   selectedItem: '聊天',
///   labelBuilder: (item) => item,
///   onSelected: (item) => setState(() => _selected = item),
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建筛选标签栏组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 筛选项定义
class MoeFilterItem<T> {
  const MoeFilterItem({
    required this.value,
    required this.label,
    this.icon,
    this.count,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final int? count;
  final bool enabled;
}

/// 筛选标签栏组件
class MoeFilterChipBar<T> extends StatelessWidget {
  const MoeFilterChipBar({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.spacing = 8,
  });

  /// 筛选项列表
  final List<MoeFilterItem<T>> items;

  /// 当前选中的值
  final T selectedValue;

  /// 选中回调
  final ValueChanged<T> onSelected;

  /// 容器内边距
  final EdgeInsets padding;

  /// 标签间距
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.borderLight)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(
          children: items.map((item) {
            final isSelected = item.value == selectedValue;
            final isEnabled = item.enabled;

            return Padding(
              padding: EdgeInsets.only(right: spacing),
              child: _FilterChip<T>(
                item: item,
                isSelected: isSelected,
                isEnabled: isEnabled,
                onTap: isEnabled ? () => onSelected(item.value) : null,
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 单个筛选标签
class _FilterChip<T> extends StatefulWidget {
  const _FilterChip({
    required this.item,
    required this.isSelected,
    required this.isEnabled,
    this.onTap,
  });

  final MoeFilterItem<T> item;
  final bool isSelected;
  final bool isEnabled;
  final VoidCallback? onTap;

  @override
  State<_FilterChip<T>> createState() => _FilterChipState<T>();
}

class _FilterChipState<T> extends State<_FilterChip<T>> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final item = widget.item;
    final isSelected = widget.isSelected;
    final isEnabled = widget.isEnabled;

    // 颜色计算
    final bgColor = isSelected
        ? colors.primary
        : (_pressed && isEnabled
            ? colors.surfaceAlt
            : colors.surface);
    final textColor = isSelected
        ? Colors.white
        : (isEnabled ? colors.text : colors.muted);
    final iconColor = isSelected
        ? Colors.white
        : (isEnabled ? colors.text : colors.muted);
    final countBgColor = isSelected
        ? colors.surface
        : colors.primary.withValues(alpha: 0.2);
    final countTextColor = isSelected ? colors.text : colors.primary;

    return GestureDetector(
      onTapDown: isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: MoeG2Decoration(
          radius: 20,
          color: bgColor,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 图标
            if (item.icon != null) ...[
              Icon(item.icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
            ],

            // 标签文字
            Text(
              item.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.emphasis,
                color: textColor,
              ),
            ),

            // 计数徽章
            if (item.count != null && item.count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: MoeG2Decoration(
                  radius: 10,
                  color: countBgColor,
                ),
                child: Text(
                  '${item.count}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: MoeFontWeights.emphasis,
                    color: countTextColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
