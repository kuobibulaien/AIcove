import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/prompts/plugin_prompts.dart';
import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/plugins/prompts/prompt_pack_store.dart';
import '../../../../ui/shared/animations/parallax_slide_page_route.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import '../widgets/preset_prompt_group.dart';
import 'prompt_pack_pages.dart';

/// 工具提示词总控台：集中管理语音、绘图的提示词包，以及所有角色共用的插件与工具提示词。
class PluginPromptsPage extends ConsumerWidget {
  const PluginPromptsPage({super.key});

  static const title = '工具提示词';

  static const _pluginOrder = <({String id, String title})>[
    (id: 'sticker', title: '表情包'),
    (id: 'time_awareness', title: '时间感知'),
    (id: 'web_search', title: '联网搜索'),
    (id: 'auto_reply', title: '主动回复与提醒'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final promptsAsync = ref.watch(pluginPromptsProvider);
    final packStateAsync = ref.watch(promptPackProvider);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: PluginPromptsPage.title,
        showBackButton: true,
      ),
      body: promptsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => MoeEmptyState(
          icon: Icons.error_outline,
          title: '读取失败',
          description: '$error',
        ),
        data: (prompts) {
          final library = packStateAsync.valueOrNull?.library;
          return MoeSettingsContent(
            child: Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(
                  context,
                  MoeSettingsLayout.verticalListPadding,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Text(
                      '集中管理所有聊天插件与工具的提示词。语音和绘图按模型分包；其余插件说明所有角色共用，也可在各插件设置页里修改。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                  if (library != null) ...[
                    _PromptPackPluginGroup(
                      title: '语音提示词包',
                      titleFirst: true,
                      pluginId: 'tts',
                      createLabel: '新建语音提示词包',
                      library: library,
                    ),
                    _PromptPackPluginGroup(
                      title: '绘图提示词包',
                      pluginId: 'image',
                      createLabel: '新建绘图提示词包',
                      library: library,
                    ),
                  ],
                  for (final (index, group) in _pluginOrder.indexed)
                    MoeSettingsGroup(
                      title: group.title,
                      titleFirst: library == null && index == 0,
                      children: [
                        for (final slot in PluginPromptSlot.forPlugin(group.id))
                          PluginPromptSlotRow(slot: slot, prompts: prompts),
                      ],
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PromptPackPluginGroup extends ConsumerWidget {
  const _PromptPackPluginGroup({
    required this.title,
    required this.pluginId,
    required this.createLabel,
    required this.library,
    this.titleFirst = false,
  });

  final String title;
  final String pluginId;
  final String createLabel;
  final PromptPackLibrary library;
  final bool titleFirst;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final packs = library.packsFor(pluginId);
    return MoeSettingsGroup(
      title: title,
      titleFirst: titleFirst,
      children: [
        for (final pack in packs)
          Builder(
            builder: (context) {
              final activePresets = promptPackActivePresets(ref, library, pack);
              final modified = isPromptPackModified(library, pack);
              final statusParts = <String>[
                if (modified) '已修改',
                if (activePresets.isNotEmpty) '${activePresets.length} 个预设在用',
              ];
              final subtitleParts = <String>[
                pack.builtIn ? '出厂' : '自建',
                if (pack.fallback) '默认',
                if (pack.description.isNotEmpty) pack.description,
              ];
              return MoeSettingsRow(
                key: ValueKey('hub-pack-${pack.id}'),
                label: pack.name,
                subtitle: subtitleParts.join(' · '),
                trailingType: MoeSettingsRowTrailing.text,
                detailText: statusParts.isEmpty
                    ? '默认'
                    : statusParts.join(' · '),
                onTap: () => Navigator.of(context).push(
                  ParallaxSlidePageRoute(
                    page: PromptPackDetailPage(packId: pack.id),
                  ),
                ),
              );
            },
          ),
        MoeSettingsRow(
          key: ValueKey('hub-create-pack-$pluginId'),
          icon: Icons.add,
          iconColor: colors.primary,
          label: createLabel,
          labelColor: colors.primary,
          trailingType: MoeSettingsRowTrailing.none,
          showDivider: true,
          onTap: () => createCustomPromptPack(context, ref, packs: packs),
        ),
        MoeSettingsRow(
          key: ValueKey('hub-import-pack-$pluginId'),
          icon: Icons.file_upload_outlined,
          iconColor: colors.primary,
          label: '从文件导入',
          labelColor: colors.primary,
          trailingType: MoeSettingsRowTrailing.none,
          showDivider: false,
          onTap: () =>
              importCustomPromptPack(context, ref, expectedPluginId: pluginId),
        ),
      ],
    );
  }
}

/// 单个全局插件提示词入口行，可在总控台和插件详情页复用。
class PluginPromptSlotRow extends StatelessWidget {
  const PluginPromptSlotRow({
    super.key,
    required this.slot,
    required this.prompts,
    this.icon,
  });

  final PluginPromptSlot slot;
  final PluginPrompts? prompts;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isDefault = prompts?.isDefault(slot) ?? true;
    return MoeSettingsRow(
      key: ValueKey('prompt-slot-${slot.name}'),
      icon: icon,
      label: slot.title,
      subtitle: slot.subtitle,
      trailingType: MoeSettingsRowTrailing.text,
      detailText: isDefault ? '默认' : '已修改',
      onTap: () => Navigator.of(context).push(
        ParallaxSlidePageRoute(page: PluginPromptSlotEditorPage(slot: slot)),
      ),
    );
  }
}

/// 按单个插件过滤的提示词列表页（供包含多个提示词槽位的插件设置页进入）。
class PluginPromptGroupPage extends ConsumerWidget {
  const PluginPromptGroupPage({
    super.key,
    required this.pluginId,
    required this.title,
  });

  final String pluginId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final promptsAsync = ref.watch(pluginPromptsProvider);
    final slots = PluginPromptSlot.forPlugin(pluginId);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(title: title, showBackButton: true),
      body: promptsAsync.when(
        loading: () => const Center(child: MoeLoadingIndicator()),
        error: (error, _) => MoeEmptyState(
          icon: Icons.error_outline,
          title: '读取失败',
          description: '$error',
        ),
        data: (prompts) => MoeSettingsContent(
          child: Builder(
            builder: (context) => ListView(
              padding: moeUnderBarPadding(
                context,
                MoeSettingsLayout.verticalListPadding,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Text(
                    '这里的提示词所有角色共用，与「设置 → 聊天插件 → 工具提示词」实时同步。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                MoeSettingsGroup(
                  children: [
                    for (final slot in slots)
                      PluginPromptSlotRow(slot: slot, prompts: prompts),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个全局插件提示词编辑页：支持自动保存与一键恢复默认。
class PluginPromptSlotEditorPage extends ConsumerStatefulWidget {
  const PluginPromptSlotEditorPage({super.key, required this.slot});

  final PluginPromptSlot slot;

  @override
  ConsumerState<PluginPromptSlotEditorPage> createState() =>
      _PluginPromptSlotEditorPageState();
}

class _PluginPromptSlotEditorPageState
    extends ConsumerState<PluginPromptSlotEditorPage>
    with MoeAutoSaveState<PluginPromptSlotEditorPage> {
  final _controller = TextEditingController();
  Object? _loadError;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(pluginPromptsProvider.future)
        .then(
          (prompts) {
            if (!mounted) return;
            _controller.text = prompts.of(widget.slot);
            autoSave.configure(
              save: _save,
              snapshot: () => moeAutoSaveSignature(_controller.text),
              fields: [_controller],
            );
            setState(() => _loaded = true);
          },
          onError: (Object error) {
            if (mounted) setState(() => _loadError = error);
          },
        );
  }

  Future<void> _save() async {
    final notifier = ref.read(pluginPromptsProvider.notifier);
    final current = await ref.read(pluginPromptsProvider.future);
    final text = _controller.text;
    if (text != current.of(widget.slot)) {
      await notifier.setText(widget.slot, text);
    }
  }

  Future<void> _restoreDefault() async {
    _controller.text = widget.slot.defaultText;
    await autoSave.flush();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final slot = widget.slot;
    final scaffold = MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: MoeAppBar(title: slot.title, showBackButton: true),
      body: _loadError != null
          ? MoeEmptyState(
              icon: Icons.error_outline,
              title: '读取失败',
              description: '$_loadError',
            )
          : !_loaded
          ? const Center(child: MoeLoadingIndicator())
          : Builder(
              builder: (context) => ListView(
                padding: moeUnderBarPadding(
                  context,
                  const EdgeInsets.fromLTRB(16, 12, 16, 24),
                ),
                children: [
                  Text(
                    '所有角色共用，修改后自动保存。${slot.subtitle}。',
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  MoeTextField(
                    controller: _controller,
                    label: '提示词内容',
                    minLines: 10,
                    maxLines: 24,
                    keyboardType: TextInputType.multiline,
                  ),
                  if (slot.hint.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      slot.hint,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ListenableBuilder(
                    listenable: _controller,
                    builder: (context, _) {
                      final isDefault =
                          _controller.text.trim() == slot.defaultText.trim();
                      if (isDefault) return const SizedBox.shrink();
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          MoeSecondaryButton(
                            label: '恢复默认',
                            size: MoeSecondaryButtonSize.sm,
                            onPressed: _restoreDefault,
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
    );
    return !_loaded ? scaffold : autoSavePage(scaffold);
  }
}
