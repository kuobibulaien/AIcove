/// 酒馆预设的提示词条目列表：按发送顺序排列，每条一个开关。
///
/// 预设详情页与聊天菜单「酒馆预设」共用，修改写回预设本身。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/silly_tavern_preset.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../shared/widgets/index.dart';
import 'tavern_common.dart';

class TavernPromptList extends ConsumerWidget {
  const TavernPromptList({super.key, required this.preset});

  final SillyTavernPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = preset.selectedOrder.entries;
    final prompts = preset.promptsById;
    final enabled = order.where((e) => e.enabled).length;
    return MoeSettingsGroup(
      title: '共 ${order.length} 条，已开启 $enabled 条',
      children: [
        if (order.isEmpty)
          const MoeSettingsRow(
            label: '这套预设没有提示词',
            trailingType: MoeSettingsRowTrailing.none,
          ),
        for (final entry in order)
          _promptRow(context, ref, entry, prompts[entry.identifier]),
      ],
    );
  }

  Widget _promptRow(
    BuildContext context,
    WidgetRef ref,
    SillyTavernPromptOrderEntry entry,
    SillyTavernPrompt? prompt,
  ) {
    final name = prompt == null || prompt.name.isEmpty
        ? entry.identifier
        : prompt.name;
    return MoeSettingsRow(
      label: name,
      labelMaxLines: 2,
      subtitle: _promptSummary(prompt),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: MoeSwitch(
        key: ValueKey('prompt-${entry.identifier}'),
        value: entry.enabled,
        semanticLabel: '启用 $name',
        onChanged: prompt == null
            ? null
            : (v) => runTavernAction(
                context,
                () => ref
                    .read(presetRecipeImportControllerProvider.notifier)
                    .change(
                      preset.id,
                      (port) =>
                          port.setPromptEnabled(preset.id, entry.identifier, v),
                    ),
              ),
      ),
      onTap: prompt == null
          ? null
          : () => showTavernText(
              context,
              title: name,
              text: prompt.marker
                  ? '这是占位条目，发送时自动填入${_markerLabel(prompt.identifier)}。关掉后这部分内容不会发给模型。'
                  : prompt.content,
            ),
    );
  }
}

String _markerLabel(String identifier) => switch (identifier) {
  'chatHistory' => '聊天记录',
  'charDescription' => '角色设定',
  'charPersonality' => '角色性格',
  'scenario' => '场景',
  'personaDescription' => '用户设定',
  'worldInfoBefore' => '世界书（角色设定前）',
  'worldInfoAfter' => '世界书（角色设定后）',
  'dialogueExamples' => '示例对话',
  _ => '动态内容',
};

String _promptSummary(SillyTavernPrompt? prompt) {
  if (prompt == null) return '找不到内容，发送时跳过';
  if (prompt.marker) return '自动填入${_markerLabel(prompt.identifier)}';
  final role = tavernRoleLabel(prompt.role);
  if (!prompt.isAbsoluteInjection) return role;
  return prompt.injectionDepth == 0
      ? '$role · 插在最新消息后'
      : '$role · 插在倒数第 ${prompt.injectionDepth} 条消息前';
}
