/// 预设选择器组件
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';
import 'edit_section_title.dart';

class PresetRecipeSection extends ConsumerWidget {
  final String? selectedRecipeId;
  final ValueChanged<String?> onRecipeChanged;

  const PresetRecipeSection({
    super.key,
    required this.selectedRecipeId,
    required this.onRecipeChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final presets = ref.watch(presetRecipeListProvider);

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EditSectionTitle(
            icon: Icons.auto_awesome_outlined,
            title: '上下文预设',
            subtitle: '可为角色绑定 SillyTavern 预设',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Material(
              color: colors.surfaceAlt.withValues(alpha: 0.35),
              child: InkWell(
                onTap: () => _showPresetPicker(context, presets),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.settings_suggest,
                          color: colors.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _presetDisplayName(presets),
                          style: TextStyle(fontSize: 14, color: colors.text),
                        ),
                      ),
                      if (selectedRecipeId != null)
                        IconButton(
                          icon: Icon(Icons.close, size: 18, color: colors.muted),
                          onPressed: () => onRecipeChanged(null),
                          tooltip: '清除绑定',
                        ),
                      Icon(Icons.chevron_right, color: colors.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _presetDisplayName(List<PresetRecipeSummary> presets) {
    if (selectedRecipeId == null) return '使用默认模式';

    final preset = presets.where((p) => p.id == selectedRecipeId).firstOrNull;
    return preset?.name ?? '已绑定自定义预设';
  }

  Future<void> _showPresetPicker(
    BuildContext context,
    List<PresetRecipeSummary> presets,
  ) async {
    const defaultToken = '__default__';

    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final colors = context.moeColors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.auto_mode, color: colors.primary),
                title: const Text('使用默认模式'),
                subtitle: const Text('直接拼接角色提示词和上下文'),
                trailing: selectedRecipeId == null
                    ? Icon(Icons.check, color: colors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(defaultToken),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: presets.length,
                  itemBuilder: (context, index) {
                    final preset = presets[index];
                    final isSelected = selectedRecipeId == preset.id;
                    return ListTile(
                      leading: const Icon(Icons.auto_awesome_outlined),
                      title: Text(preset.name),
                      subtitle: Text(preset.description),
                      trailing: isSelected
                          ? Icon(Icons.check, color: colors.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop(preset.id),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (selected == null) return;
    if (selected == defaultToken) {
      onRecipeChanged(null);
    } else {
      onRecipeChanged(selected);
    }
  }
}
