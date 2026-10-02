import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/domain/tavern_compatibility_port.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../widgets/tavern_common.dart';
import 'tavern_preset_detail_page.dart';

/// 酒馆兼容插件首页：管理预设列表与默认预设。
class TavernPluginDetailPage extends ConsumerWidget {
  const TavernPluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(tavernPluginSettingsProvider);
    final presets = ref.watch(presetRecipeListProvider);
    final busy = ref.watch(presetRecipeImportControllerProvider).isLoading;
    final colors = context.moeColors;
    final defaultId = settings.valueOrNull?.defaultPresetId;
    final list = presets.valueOrNull ?? const <PresetRecipeSummary>[];
    final loading =
        (settings.isLoading && !settings.hasValue) ||
        (presets.isLoading && !presets.hasValue);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '酒馆兼容插件（测试）', showBackButton: true),
      body: MoeSettingsContent(
        child: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              MoeSettingsLayout.verticalListPadding,
            ),
            children: [
              TavernNote(
                defaultId == null
                    ? '一套预设包含提示词、正则和世界书。角色可以在编辑页单独绑定；还没设默认预设，没绑定的角色按 AIcove 原来的方式聊天。'
                    : '一套预设包含提示词、正则和世界书。角色可以在编辑页单独绑定；没绑定的角色使用标着「默认」的那套。',
              ),
              if (settings.hasError || presets.hasError) ...[
                const SizedBox(height: MoeSettingsLayout.sectionGap),
                _ErrorGroup(settingsBroken: settings.hasError, busy: busy),
              ],
              MoeSettingsGroup(
                title: '我的预设',
                children: [
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  for (final preset in list)
                    _PresetRow(
                      preset: preset,
                      isDefault: preset.id == defaultId,
                      canSetDefault: settings.hasValue && !busy,
                    ),
                  MoeSettingsRow(
                    label: '导入预设',
                    subtitle: '选择酒馆导出的预设 JSON',
                    labelColor: colors.primary,
                    enabled: !busy,
                    trailingType: MoeSettingsRowTrailing.none,
                    onTap: () => _import(context, ref),
                  ),
                  MoeSettingsRow(
                    label: '新建空白预设',
                    subtitle: '只想用正则或世界书时选这个',
                    labelColor: colors.primary,
                    enabled: !busy,
                    trailingType: MoeSettingsRowTrailing.none,
                    onTap: () => runTavernAction(context, () async {
                      final preset = await ref
                          .read(presetRecipeImportControllerProvider.notifier)
                          .createBasicPreset();
                      if (context.mounted) openTavernPreset(context, preset.id);
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _import(
    BuildContext context,
    WidgetRef ref,
  ) => runTavernAction(context, () async {
    final file = await pickTavernJson();
    if (file == null || !context.mounted) return;
    final controller = ref.read(presetRecipeImportControllerProvider.notifier);
    final preview = controller.previewSource(
      file.source,
      sourceFileName: file.name,
    );
    final colors = context.moeColors;
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '导入「${preview.name}」',
      cancelText: '取消',
      confirmText: '导入',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(PresetRecipeSummary.fromPreset(preview).description),
          const SizedBox(height: 8),
          Text(
            preview.regexScriptCount > 0
                ? '导入后可以逐条开关。正则默认不运行，需要到「正则」里手动允许。'
                : '导入后可以逐条开关。',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
          if (preview.warnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              [
                for (final warning in preview.warnings.take(3)) '· $warning',
                if (preview.warnings.length > 3)
                  '另有 ${preview.warnings.length - 3} 条提示，导入后可在「预设信息」查看',
              ].join('\n'),
              style: TextStyle(fontSize: 13, color: colors.toastWarning),
            ),
          ],
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final preset = await controller.importSource(
      file.source,
      sourceFileName: file.name,
    );
    if (context.mounted) openTavernPreset(context, preset.id);
  });
}

void openTavernPreset(BuildContext context, String id) => Navigator.of(
  context,
).push(ParallaxSlidePageRoute(page: TavernPresetDetailPage(presetId: id)));

class _PresetRow extends ConsumerWidget {
  const _PresetRow({
    required this.preset,
    required this.isDefault,
    required this.canSetDefault,
  });

  final PresetRecipeSummary preset;
  final bool isDefault;
  final bool canSetDefault;

  void _setDefault(BuildContext context, WidgetRef ref) => runTavernAction(
    context,
    () => ref
        .read(presetRecipeImportControllerProvider.notifier)
        .change(
          null,
          (port) => port.savePluginSettings(
            TavernPluginSettings(defaultPresetId: isDefault ? null : preset.id),
          ),
        ),
  );

  void _showMenu(BuildContext context, WidgetRef ref, BuildContext anchor) =>
      MoePopupMenu.show(
        anchor,
        targetBox: anchor.findRenderObject()! as RenderBox,
        alignToEnd: true,
        items: [
          MoePopupMenuItem(
            label: '打开',
            onTap: () => openTavernPreset(context, preset.id),
          ),
          if (canSetDefault)
            MoePopupMenuItem(
              label: isDefault ? '取消默认' : '设为默认',
              onTap: () => _setDefault(context, ref),
            ),
          MoePopupMenuItem(
            key: ValueKey('delete-tavern-preset-${preset.id}'),
            label: '删除',
            danger: true,
            onTap: () => confirmDeleteTavernPreset(
              context,
              ref,
              presetId: preset.id,
              name: preset.name,
              isDefault: isDefault,
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    return Builder(
      builder: (anchor) => MoeSettingsRow(
        key: ValueKey('tavern-preset-${preset.id}'),
        label: preset.name,
        labelMaxLines: 2,
        subtitle: preset.description,
        trailingType: MoeSettingsRowTrailing.custom,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isDefault) const TavernBadge('默认'),
            IconButton(
              tooltip: '更多操作',
              icon: Icon(Icons.more_horiz, size: 20, color: colors.muted),
              onPressed: () => _showMenu(context, ref, anchor),
            ),
            Icon(Icons.chevron_right, size: 20, color: colors.muted),
          ],
        ),
        onTap: () => openTavernPreset(context, preset.id),
        onLongPress: () => _showMenu(context, ref, anchor),
      ),
    );
  }
}

class _ErrorGroup extends ConsumerWidget {
  const _ErrorGroup({required this.settingsBroken, required this.busy});

  final bool settingsBroken;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    return MoeSettingsGroup(
      children: [
        MoeSettingsRow(
          label: '读取失败',
          subtitle: settingsBroken ? '插件设置文件损坏，预设本身不受影响' : '预设列表没能读出来',
          labelColor: colors.toastWarning,
          trailingType: MoeSettingsRowTrailing.none,
        ),
        MoeSettingsRow(
          label: '重试',
          labelColor: colors.primary,
          trailingType: MoeSettingsRowTrailing.none,
          onTap: () {
            ref.invalidate(tavernPluginSettingsProvider);
            ref.invalidate(presetRecipeListProvider);
          },
        ),
        if (settingsBroken)
          MoeSettingsRow(
            label: '重置默认选择',
            subtitle: '只清除默认预设，不删除预设和角色绑定',
            labelColor: colors.primary,
            enabled: !busy,
            trailingType: MoeSettingsRowTrailing.none,
            onTap: () => runTavernAction(context, () async {
              final confirmed = await showMeoTalkDialog(
                context: context,
                title: '重置默认选择',
                cancelText: '取消',
                confirmText: '确认重置',
                content: const Text('清除默认预设选择；不删除预设、正则、世界书或角色绑定。重置后可以重新选默认预设。'),
              );
              if (confirmed != true || !context.mounted) return;
              await ref
                  .read(presetRecipeImportControllerProvider.notifier)
                  .change(
                    null,
                    (port) =>
                        port.savePluginSettings(const TavernPluginSettings()),
                  );
            }),
          ),
      ],
    );
  }
}
