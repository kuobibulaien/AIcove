/// CapabilitySelector - 用途多选组件
///
/// 用于选择供应商支持的模型用途。
///
/// 设计特点：
/// - 4 个可选项：对话/嵌入/图片/语音
/// - Checkbox 风格，支持多选（MoeChoiceChip）
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
import '../../../theme/tokens.dart';
import '../buttons/moe_choice_chip.dart';
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
              Expanded(
                child: _buildItem(context, ModelCapability.chat, colors),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildItem(context, ModelCapability.embedding, colors),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildItem(context, ModelCapability.image, colors),
              ),
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

  Widget _buildItem(
    BuildContext context,
    ModelCapability cap,
    MoeColors colors,
  ) {
    return MoeChoiceChip(
      label: cap.label,
      icon: cap.icon,
      selected: selected.contains(cap.value),
      indicator: MoeChoiceIndicator.check,
      expand: compact,
      onTap: enabled ? () => _toggle(cap) : null,
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
            Expanded(
              child: _buildItem(context, ModelCapability.embedding, colors),
            ),
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

  Widget _buildItem(
    BuildContext context,
    ModelCapability cap,
    MoeColors colors,
  ) {
    return MoeChoiceChip(
      label: cap.label,
      icon: cap.icon,
      selected: selected == cap.value,
      indicator: MoeChoiceIndicator.radio,
      expand: true,
      onTap: enabled
          ? () {
              if (selected != cap.value) onChanged(cap.value);
            }
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
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (showAll) ...[
            _buildFilterChip(
              context,
              label: '全部',
              isSelected: selected == null,
              onTap: () => onChanged(null),
            ),
            const SizedBox(width: 8),
          ],
          ...ModelCapability.values.map(
            (cap) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildFilterChip(
                context,
                label: cap.label,
                icon: cap.icon,
                isSelected: selected == cap.value,
                onTap: () => onChanged(cap.value),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(
    BuildContext context, {
    required String label,
    IconData? icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return MoeChoiceChip(
      label: label,
      icon: icon,
      selected: isSelected,
      size: MoeChoiceChipSize.sm,
      onTap: onTap,
    );
  }
}
