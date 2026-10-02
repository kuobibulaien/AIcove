import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/chat/application/chat_page_conversation_actions.dart';
import '../../../../features/chat/conversation_providers.dart'
    show resolvedConversationByIdProvider;
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../character/widgets/preset_recipe_section.dart';
import '../../plugins/pages/tavern_preset_detail_page.dart';
import '../../plugins/widgets/tavern_common.dart';
import '../../plugins/widgets/tavern_prompt_list.dart';

/// 聊天菜单「酒馆预设」：切换本角色使用的预设，并逐条开关它的提示词。
class ChatTavernPresetPage extends ConsumerWidget {
  const ChatTavernPresetPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final boundId = ref
        .watch(resolvedConversationByIdProvider(conversationId))
        ?.recipeId;
    final presets =
        ref.watch(presetRecipeListProvider).valueOrNull ??
        const <PresetRecipeSummary>[];
    final defaultId = ref
        .watch(tavernPluginSettingsProvider)
        .valueOrNull
        ?.defaultPresetId;
    // 明确绑定的预设丢失时不回退默认，与请求链路一致。
    final effectiveId = boundId ?? defaultId;
    final preset = effectiveId == null
        ? null
        : ref.watch(presetRecipeProvider(effectiveId));

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '酒馆预设', showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              MoeSettingsGroup(
                children: [
                  MoeSettingsRow(
                    label: '当前预设',
                    trailingType: MoeSettingsRowTrailing.text,
                    detailText: boundId == null
                        ? tavernPresetDisplayName(presets, null)
                        : preset?.valueOrNull?.name ??
                              tavernPresetDisplayName(presets, boundId),
                    onTap: () => showTavernPresetPicker(
                      context: context,
                      selectedRecipeId: boundId,
                      onChanged: (id) => runTavernAction(
                        context,
                        () => ref
                            .read(chatPageConversationActionsProvider)
                            .applyConversationEdits(
                              conversationId,
                              recipeId: id,
                              clearRecipeId: id == null,
                            ),
                      ),
                    ),
                  ),
                  if (effectiveId != null && preset?.valueOrNull != null)
                    MoeSettingsRow(
                      label: '正则、世界书与标签',
                      onTap: () => MoeWorkspace.open(
                        context,
                        TavernPresetDetailPage(presetId: effectiveId),
                      ),
                    ),
                ],
              ),
              ...switch (preset) {
                null => const [
                  TavernNote('还没有可用的酒馆预设，本角色按 AIcove 原来的方式聊天。可以在插件页导入预设或设置默认预设。'),
                ],
                AsyncValue(isLoading: true, hasValue: false) => const [
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                AsyncValue(:final valueOrNull) when valueOrNull == null => [
                  TavernNote(
                    boundId != null
                        ? '绑定的预设已丢失，请重新选择。'
                        : '默认预设读取失败，请到插件页检查。',
                  ),
                ],
                AsyncValue(:final valueOrNull) => [
                  const TavernNote(
                    '关掉的条目不会发给模型。开关改的是预设本身，所有用这套预设的角色都会跟着变，从下一条消息起生效。',
                  ),
                  TavernPromptList(preset: valueOrNull!),
                ],
              },
            ],
          ),
        ),
      ),
    );
  }
}
