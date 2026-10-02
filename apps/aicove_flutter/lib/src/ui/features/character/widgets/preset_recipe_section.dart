/// 角色编辑页的酒馆预设绑定：显示名与选择弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 角色已绑定预设的显示名。
String tavernPresetDisplayName(
  List<PresetRecipeSummary> presets,
  String? selectedRecipeId,
) {
  if (selectedRecipeId == null) return '跟随默认酒馆预设';
  final preset = presets.where((p) => p.id == selectedRecipeId).firstOrNull;
  return preset?.name ?? '绑定的预设已丢失，请重新选择';
}

/// 酒馆预设选择弹窗。[onChanged] 收到 null 表示改为跟随默认酒馆预设。
Future<void> showTavernPresetPicker({
  required BuildContext context,
  required String? selectedRecipeId,
  required ValueChanged<String?> onChanged,
}) => showMoeBottomSheet<void>(
  context: context,
  title: '选择酒馆预设',
  showCloseButton: true,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final colors = context.moeColors;
      final presets =
          ref.watch(presetRecipeListProvider).valueOrNull ??
          const <PresetRecipeSummary>[];
      final defaultId = ref
          .watch(tavernPluginSettingsProvider)
          .valueOrNull
          ?.defaultPresetId;
      final defaultName = presets
          .where((p) => p.id == defaultId)
          .firstOrNull
          ?.name;
      Widget? check(bool selected) =>
          selected ? Icon(Icons.check, color: colors.primary) : null;
      void select(String? id) {
        onChanged(id);
        Navigator.of(context).pop();
      }

      return ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: presets.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return MoeListTile(
              title: const Text('跟随默认酒馆预设'),
              subtitle: Text(
                defaultName == null
                    ? '还没设默认预设，按 AIcove 原来的方式聊天'
                    : '现在是「$defaultName」',
              ),
              trailing: check(selectedRecipeId == null),
              onTap: () => select(null),
            );
          }
          final preset = presets[index - 1];
          return MoeListTile(
            title: Text(preset.name),
            subtitle: Text(preset.description),
            trailing: check(selectedRecipeId == preset.id),
            onTap: () => select(preset.id),
          );
        },
      );
    },
  ),
);
