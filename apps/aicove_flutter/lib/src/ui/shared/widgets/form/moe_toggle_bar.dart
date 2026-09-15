/// MoeToggleBar - 单选切换框组件
///
/// 用于在多个选项中单选切换，类似 iOS 分段控制器。
///
/// 设计特点：
/// - 单选模式（与 MoeSegTabBar 类似但语义更明确）
/// - 支持图标+文字组合
/// - 接入主题系统
/// - iOS 触觉反馈
///
/// 使用示例：
/// ```dart
/// MoeToggleBar<String>(
///   value: _selected,
///   items: [
///     MoeToggleItem(value: 'openai', label: 'OpenAI'),
///     MoeToggleItem(value: 'claude', label: 'Claude'),
///     MoeToggleItem(value: 'gemini', label: 'Gemini'),
///   ],
///   onChanged: (v) => setState(() => _selected = v),
/// )
/// ```
///
/// 更新记录：
/// - 2026-01-22: 创建单选切换框组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../buttons/moe_button_surface.dart';
import '../moe_floating_surface.dart';

/// 切换项配置
class MoeToggleItem<T> {
  const MoeToggleItem({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// 单选切换框组件
class MoeToggleBar<T> extends StatelessWidget {
  const MoeToggleBar({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.expanded = true,
  });

  /// 当前选中值
  final T value;

  /// 选项列表
  final List<MoeToggleItem<T>> items;

  /// 值变化回调
  final ValueChanged<T> onChanged;

  /// 是否撑满宽度（默认 true）
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return MoeFloatingSurface(
      radius: 20,
      padding: const EdgeInsets.all(3),
      child: SizedBox(
        height: 34,
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          children: items.map((item) {
            final isSelected = value == item.value;
            final child = _buildItem(context, item, isSelected, colors);
            return expanded ? Expanded(child: child) : child;
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    MoeToggleItem<T> item,
    bool isSelected,
    MoeColors colors,
  ) {
    return GestureDetector(
      onTap: () {
        if (value != item.value) {
          HapticFeedback.lightImpact();
          onChanged(item.value);
        }
      },
      child: MoeButtonSurface(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        radius: 17,
        tintColor: isSelected ? colors.focus : Colors.transparent,
        shadows: const [],
        alignment: Alignment.center,
        child: item.icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.icon,
                    size: 16,
                    color: isSelected ? colors.text : colors.muted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: isSelected ? colors.text : colors.textSecondary,
                      fontWeight: isSelected
                          ? MoeFontWeights.emphasis
                          : MoeFontWeights.normal,
                    ),
                  ),
                ],
              )
            : Text(
                item.label,
                style: TextStyle(
                  fontSize: 13,
                  color: isSelected ? colors.text : colors.textSecondary,
                  fontWeight: isSelected
                      ? MoeFontWeights.emphasis
                      : MoeFontWeights.normal,
                ),
              ),
      ),
    );
  }
}
