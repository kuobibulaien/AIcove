/// CapabilitySelector - 用途多选组件
/// 
/// 用于选择供应商支持的模型用途。
/// 
/// 设计特点：
/// - 4 个可选项：对话/嵌入/图片/语音
/// - Checkbox 风格，支持多选
/// - 每项带图标和文字
/// - 触觉反馈
/// 
/// 使用示例：
/// ```dart
/// CapabilitySelector(
///   selected: {'chat'},
///   onChanged: (caps) => setState(() => _caps = caps),
/// )
/// ```
/// 
/// 更新记录：
/// - 2026-01-21: 创建用途多选组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';
import 'capability_chips.dart';

/// 用途多选组件
class CapabilitySelector extends StatelessWidget {
  const CapabilitySelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  /// 已选中的能力
  final Set<String> selected;

  /// 选择变化回调
  final ValueChanged<Set<String>> onChanged;

  /// 是否启用
  final bool enabled;

  /// 紧凑模式（2x2 布局）
  final bool compact;

  void _toggle(ModelCapability cap) {
    if (!enabled) return;
    
    HapticFeedback.lightImpact();
    
    final newSet = Set<String>.from(selected);
    if (newSet.contains(cap.value)) {
      // 至少保留一个
      if (newSet.length > 1) {
        newSet.remove(cap.value);
      }
    } else {
      newSet.add(cap.value);
    }
    onChanged(newSet);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    if (compact) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildItem(context, ModelCapability.chat, colors)),
              const SizedBox(width: 12),
              Expanded(child: _buildItem(context, ModelCapability.embedding, colors)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildItem(context, ModelCapability.image, colors)),
              const SizedBox(width: 12),
              Expanded(child: _buildItem(context, ModelCapability.tts, colors)),
            ],
          ),
        ],
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: ModelCapability.values
          .map((cap) => _buildItem(context, cap, colors))
          .toList(),
    );
  }

  Widget _buildItem(BuildContext context, ModelCapability cap, MoeColors colors) {
    final isSelected = selected.contains(cap.value);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // 使用项目定义的次级表面背景色
    final bgColor = isSelected
        ? cap.color.withValues(alpha: isDark ? 0.2 : 0.12)
        : colors.surface;
    
    // 边框色使用主题边框色，选中时使用能力主色
    final borderColor = isSelected ? cap.color : colors.border;
    final iconColor = isSelected ? cap.color : colors.muted;
    final textColor = isSelected ? colors.text : colors.textSecondary;

    return GestureDetector(
      onTap: () => _toggle(cap),
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: MoeG2Decoration(
          radius: MoeRadii.md,
          color: bgColor,
          border: Border.all(
            color: borderColor,
            width: isSelected ? 1.5 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCheckbox(isSelected, cap.color, colors),
            const SizedBox(width: 10),
            Icon(cap.icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Text(
              cap.label,
              style: TextStyle(
                fontSize: 14,
                color: textColor,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool isSelected, Color activeColor, MoeColors colors) {
    return AnimatedContainer(
      duration: kAnimFast,
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? activeColor : Colors.transparent,
        border: Border.all(
          color: isSelected ? activeColor : colors.border,
          width: 1.5,
        ),
      ),
      child: isSelected
          ? const Icon(Icons.check, size: 12, color: Colors.white)
          : null,
    );
  }
}

/// 用途单选组件（用于导入供应商时选择）
class CapabilitySingleSelector extends StatelessWidget {
  const CapabilitySingleSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  /// 当前选中的能力
  final String selected;

  /// 选择变化回调
  final ValueChanged<String> onChanged;

  /// 是否启用
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildItem(context, ModelCapability.chat, colors)),
            const SizedBox(width: 12),
            Expanded(child: _buildItem(context, ModelCapability.embedding, colors)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildItem(context, ModelCapability.image, colors)),
            const SizedBox(width: 12),
            Expanded(child: _buildItem(context, ModelCapability.tts, colors)),
          ],
        ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, ModelCapability cap, MoeColors colors) {
    final isSelected = selected == cap.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bgColor = isSelected
        ? cap.color.withValues(alpha: isDark ? 0.2 : 0.12)
        : colors.surface;

    final borderColor = isSelected ? cap.color : colors.border;
    final iconColor = isSelected ? cap.color : colors.muted;
    final textColor = isSelected ? colors.text : colors.textSecondary;

    return GestureDetector(
      onTap: enabled ? () {
        if (selected != cap.value) {
          HapticFeedback.lightImpact();
          onChanged(cap.value);
        }
      } : null,
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: MoeG2Decoration(
          radius: MoeRadii.md,
          color: bgColor,
          border: Border.all(
            color: borderColor,
            width: isSelected ? 1.5 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildRadio(isSelected, cap.color, colors),
            const SizedBox(width: 10),
            Icon(cap.icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Text(
              cap.label,
              style: TextStyle(
                fontSize: 14,
                color: textColor,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadio(bool isSelected, Color activeColor, MoeColors colors) {
    return AnimatedContainer(
      duration: kAnimFast,
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? activeColor : Colors.transparent,
        border: Border.all(
          color: isSelected ? activeColor : colors.border,
          width: 1.5,
        ),
      ),
      child: isSelected
          ? Center(
              child: Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            )
          : null,
    );
  }
}

/// 能力类型单选组件（用于筛选）
class CapabilityFilter extends StatelessWidget {
  const CapabilityFilter({
    super.key,
    required this.selected,
    required this.onChanged,
    this.showAll = true,
  });

  /// 当前选中的能力（null 表示全部）
  final String? selected;

  /// 选择变化回调
  final ValueChanged<String?> onChanged;

  /// 是否显示"全部"选项
  final bool showAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (showAll) ...[
            _buildFilterChip(
              context,
              label: '全部',
              isSelected: selected == null,
              color: colors.focus,
              isDark: isDark,
              onTap: () => onChanged(null),
            ),
            const SizedBox(width: 8),
          ],
          ...ModelCapability.values.map((cap) => Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildFilterChip(
              context,
              label: cap.label,
              icon: cap.icon,
              isSelected: selected == cap.value,
              color: cap.color,
              isDark: isDark,
              onTap: () => onChanged(cap.value),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildFilterChip(
    BuildContext context, {
    required String label,
    IconData? icon,
    required bool isSelected,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final colors = context.moeColors;
    final bgColor = isSelected
        ? color.withValues(alpha: isDark ? 0.25 : 0.15)
        : colors.surface;
    final fgColor = isSelected ? color : colors.textSecondary;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: MoeG2Decoration(
          radius: 16,
          color: bgColor,
          border: Border.all(
            color: isSelected ? color.withValues(alpha: 0.5) : colors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: fgColor),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: fgColor,
                fontWeight: isSelected ? MoeFontWeights.emphasis : MoeFontWeights.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
