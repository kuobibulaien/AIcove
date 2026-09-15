import 'package:flutter/material.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/drawing_preset.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import 'drawing_preset_editor_page.dart';
import 'image_generation_test_page.dart';

class ImagePluginDetailPage extends ConsumerWidget {
  const ImagePluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogAsync = ref.watch(drawingPresetCatalogProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final colors = context.moeColors;

    return MoePageScaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '绘图预设', showBackButton: true),
      body: catalogAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('绘图预设加载失败：$error'),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => ref.invalidate(drawingPresetCatalogProvider),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
        data: (catalog) => settingsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('设置加载失败：$error')),
          data: (settings) => MoeSettingsContent(
            child: ListView(
              padding: MoeSettingsLayout.verticalListPadding,
              children: [
                MoeSettingsGroup(
                  padding: MoeSettingsLayout.contentPadding,
                  children: [
                    Text(
                      '每张角色卡可绑定一个绘图预设。未绑定时使用默认预设；编辑共享预设会影响所有绑定角色。',
                      style: TextStyle(fontSize: 13, color: colors.muted),
                    ),
                  ],
                ),
                const SizedBox(height: MoeSettingsLayout.sectionGap),
                MoeSettingsGroup(
                  title: '预设列表',
                  children: [
                    for (final preset in catalog.presets)
                      _buildPresetRow(
                        context: context,
                        ref: ref,
                        preset: preset,
                        catalog: catalog,
                        settings: settings,
                        colors: colors,
                      ),
                    MoeSettingsRow(
                      key: const ValueKey('add-drawing-preset'),
                      label: '新建绘图预设',
                      labelColor: colors.primary,
                      trailingType: MoeSettingsRowTrailing.chevron,
                      onTap: () => _edit(
                        context,
                        catalog.require(catalog.defaultPresetId),
                        isNew: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: MoeSettingsLayout.sectionGap),
                MoeSettingsGroup(
                  title: '生图方式',
                  children: [
                    for (final mode in [CallFlowMode.auto, CallFlowMode.fast])
                      MoeSettingsRow(
                        label: mode == CallFlowMode.auto ? '自动模式' : '快速模式',
                        subtitle: mode == CallFlowMode.auto
                            ? '按对话模型能力自动选择'
                            : '通过图片标签直连生图',
                        trailingType: mode == settings.callFlowSettings.mode
                            ? MoeSettingsRowTrailing.custom
                            : MoeSettingsRowTrailing.none,
                        trailing: mode == settings.callFlowSettings.mode
                            ? Icon(Icons.check, color: colors.primary)
                            : null,
                        onTap: () => _perform(
                          context,
                          () => ref
                              .read(appSettingsProvider.notifier)
                              .updateCallFlowSettings(
                                settings.callFlowSettings.copyWith(mode: mode),
                              ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetRow({
    required BuildContext context,
    required WidgetRef ref,
    required DrawingPreset preset,
    required DrawingPresetCatalog catalog,
    required AppSettings settings,
    required MoeColors colors,
  }) {
    final isDefault = preset.id == catalog.defaultPresetId;
    final modelText = preset.config.selectedModelId == null
        ? '待选择渠道与模型'
        : settings.getModelDisplayName(preset.config.selectedModelId!);
    final subtitle =
        '$modelText · ${preset.config.defaultWidth} × ${preset.config.defaultHeight} · ${preset.config.defaultCount} 张';

    return MoeSettingsRow(
      key: ValueKey('drawing-preset-${preset.id}'),
      label: preset.name,
      subtitle: isDefault ? '默认预设 · $subtitle' : subtitle,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDefault)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '默认',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: colors.primary,
                ),
              ),
            ),
          Builder(
            builder: (menuContext) => IconButton(
              key: ValueKey('preset-menu-${preset.id}'),
              icon: Icon(Icons.more_vert, size: 20, color: colors.muted),
              tooltip: '更多操作',
              onPressed: () => MoePopupMenu.show(
                menuContext,
                targetBox: menuContext.findRenderObject()! as RenderBox,
                alignToEnd: true,
                items: [
                  MoePopupMenuItem(
                    label: '编辑',
                    onTap: () => _edit(context, preset),
                  ),
                  MoePopupMenuItem(
                    label: '复制',
                    onTap: () => _edit(context, preset, isNew: true),
                  ),
                  if (!isDefault)
                    MoePopupMenuItem(
                      label: '设为默认',
                      onTap: () => _perform(
                        context,
                        () => ref
                            .read(drawingPresetCatalogProvider.notifier)
                            .setDefault(preset.id),
                      ),
                    ),
                  MoePopupMenuItem(
                    label: '测试',
                    onTap: () => Navigator.push(
                      context,
                      ParallaxSlidePageRoute(
                        page: ImageGenerationTestPage(
                          drawingConfig: preset.config,
                          initialModelLabel: preset.name,
                        ),
                      ),
                    ),
                  ),
                  MoePopupMenuItem(
                    key: ValueKey('delete-drawing-${preset.id}'),
                    label: '删除',
                    danger: true,
                    onTap: () => _delete(context, ref, preset),
                  ),
                ],
              ),
            ),
          ),
          Icon(Icons.chevron_right, size: 20, color: colors.muted),
        ],
      ),
      onTap: () => _edit(context, preset),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    DrawingPreset preset,
  ) async {
    final catalog = ref.read(drawingPresetCatalogProvider).requireValue;
    if (preset.id == catalog.defaultPresetId) {
      MoeToast.error(context, '这是默认绘图预设，请先将其他预设设为默认');
      return;
    }
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除绘图预设？',
      content: Text('确定删除「${preset.name}」？删除后无法恢复。仍有角色使用的预设不会被删除。'),
      cancelText: '取消',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(drawingPresetCatalogProvider.notifier)
          .deletePreset(preset.id);
      if (context.mounted) MoeToast.success(context, '绘图预设已删除');
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '删除失败：$e');
    }
  }

  Future<void> _perform(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '保存失败：$e');
    }
  }

  void _edit(BuildContext context, DrawingPreset preset, {bool isNew = false}) {
    Navigator.push(
      context,
      ParallaxSlidePageRoute(
        page: DrawingPresetEditorPage(preset: preset, isNew: isNew),
      ),
    );
  }
}
