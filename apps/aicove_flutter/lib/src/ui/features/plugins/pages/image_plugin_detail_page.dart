import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';
import 'drawing_prompt_page.dart';

class ImagePluginDetailPage extends ConsumerWidget {
  const ImagePluginDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;
    final settingsAsync = ref.watch(appSettingsProvider);
    final imageConfig = ref.watch(imagePluginConfigProvider);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '绘图设置',
        showBackButton: true,
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载设置失败: $e')),
        data: (settings) => _buildBody(
          context: context,
          ref: ref,
          settings: settings,
          config: imageConfig,
        ),
      ),
    );
  }

  Widget _buildBody({
    required BuildContext context,
    required WidgetRef ref,
    required AppSettings settings,
    required ImageConfig config,
  }) {
    final colors = context.moeColors;
    final configNotifier = ref.read(imagePluginConfigProvider.notifier);
    final settingsNotifier = ref.read(appSettingsProvider.notifier);

    // 直接从所有可见模型中筛选 image 类型
    final imageModels = _allImageModels(settings);
    final selectedModel = _resolveSelectedModel(
      config: config,
      imageModels: imageModels,
    );

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        MoeSettingsGroup(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            MoeSettingsRow(
              icon: Icons.brush_outlined,
              label: '启用绘图工具',
              subtitle: settings.imageGenerationEnabled ? '已启用' : '已禁用',
              subtitleColor: settings.imageGenerationEnabled
                  ? colors.primary
                  : colors.muted,
              trailingType: MoeSettingsRowTrailing.switchControl,
              switchValue: settings.imageGenerationEnabled,
              onSwitchChanged: (value) =>
                  settingsNotifier.setImageGenerationEnabled(value),
            ),
            MoeSettingsRow(
              icon: Icons.auto_awesome_outlined,
              label: selectedModel?.displayName ?? '自动选择首个模型',
              subtitle: imageModels.isEmpty
                  ? '暂无可用图片模型，请先到渠道商管理添加'
                  : '模型来源：渠道商管理中的模型列表',
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: imageModels.isEmpty
                  ? () => MoeToast.show(context, '暂无可用图片模型')
                  : () => _showModelPicker(
                        context: context,
                        ref: ref,
                        imageModels: imageModels,
                        config: config,
                      ),
            ),
            MoeSettingsRow(
              icon: Icons.rule_folder_outlined,
              label: '生图提示词预设',
              subtitle: config.selectedSystemPromptPreset?.name ?? '手动自定义',
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: () => _showSystemPromptPresetPicker(
                context: context,
                notifier: configNotifier,
                config: config,
              ),
              showDivider: false,
            ),
          ],
        ),
        const SizedBox(height: 16),
        MoeSettingsGroup(
          title: '默认参数',
          margin: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            MoeSettingsRow(
              icon: Icons.crop_outlined,
              label: '默认尺寸',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '${config.defaultWidth} x ${config.defaultHeight}',
              onTap: () => _showSizePicker(
                context: context,
                notifier: configNotifier,
              ),
            ),
            MoeSettingsRow(
              icon: Icons.timeline_outlined,
              label: '默认步数',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '${config.defaultSteps}',
              onTap: () => _showStepsPicker(
                context: context,
                notifier: configNotifier,
                current: config.defaultSteps,
              ),
            ),
            MoeSettingsRow(
              icon: Icons.tune_outlined,
              label: '默认提示词强度',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: config.defaultGuidanceScale.toStringAsFixed(1),
              onTap: () => _showGuidancePicker(
                context: context,
                notifier: configNotifier,
                current: config.defaultGuidanceScale,
              ),
            ),
            MoeSettingsRow(
              icon: Icons.collections_outlined,
              label: '默认生成张数',
              trailingType: MoeSettingsRowTrailing.text,
              detailText: '${config.defaultCount}',
              onTap: () => _showCountPicker(
                context: context,
                notifier: configNotifier,
                current: config.defaultCount,
              ),
            ),
            MoeSettingsRow(
              icon: Icons.block_outlined,
              label: '默认负面提示词',
              subtitle: config.defaultNegativePrompt.trim().isEmpty
                  ? '未设置'
                  : config.defaultNegativePrompt.trim(),
              labelMaxLines: 1,
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: () => _editNegativePrompt(
                context: context,
                notifier: configNotifier,
                current: config.defaultNegativePrompt,
              ),
              showDivider: false,
            ),
          ],
        ),
        const SizedBox(height: 16),
        MoeSettingsGroup(
          title: '高级设置',
          margin: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            MoeSettingsRow(
              icon: Icons.description_outlined,
              label: '绘图提示词',
              subtitle: _buildPromptSummary(config),
              labelMaxLines: 1,
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const DrawingPromptPage(),
                ),
              ),
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }

  /// 图片模型条目
  List<_ImageModelEntry> _allImageModels(AppSettings settings) {
    final result = <_ImageModelEntry>[];
    for (final provider in settings.providers) {
      if (!provider.enabled) continue;
      final models = provider.visibleModels.isNotEmpty
          ? provider.visibleModels
          : provider.models;
      for (final modelId in models) {
        final modelRef = settings.buildModelRef(provider.id, modelId);
        if (settings.getModelType(modelRef) == ModelType.image) {
          result.add(_ImageModelEntry(
            modelRef: modelRef,
            modelId: modelId,
            providerId: provider.id,
            providerName: provider.displayName ?? provider.id,
            displayName: settings.getModelDisplayName(modelRef),
          ));
        }
      }
    }
    return result;
  }

  _ImageModelEntry? _resolveSelectedModel({
    required ImageConfig config,
    required List<_ImageModelEntry> imageModels,
  }) {
    if (imageModels.isEmpty) return null;
    final selected = config.selectedModelId?.trim();
    if (selected != null && selected.isNotEmpty) {
      final match =
          imageModels.where((m) => m.modelRef == selected).firstOrNull;
      if (match != null) return match;
    }
    return imageModels.first;
  }

  Future<void> _showModelPicker({
    required BuildContext context,
    required WidgetRef ref,
    required List<_ImageModelEntry> imageModels,
    required ImageConfig config,
  }) async {
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    if (imageModels.isEmpty) {
      MoeToast.show(context, '暂无可用图片模型');
      return;
    }

    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: config.selectedModelId == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '自动选择',
        subtitle: '使用第一个可用模型',
        onTap: () => notifier.setSelectedModel(null),
      ),
      for (final model in imageModels)
        MoeSheetAction(
          icon: config.selectedModelId == model.modelRef
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: model.displayName,
          subtitle: '${model.providerName} / ${model.modelId}',
          onTap: () => notifier.setSelectedModel(model.modelRef),
        ),
    ];

    await showMoeActionSheet(
      context: context,
      title: '选择绘图模型',
      actions: actions,
    );
  }

  Future<void> _showSystemPromptPresetPicker({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
    required ImageConfig config,
  }) async {
    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: config.selectedSystemPromptPresetName == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '手动自定义',
        subtitle: '使用「绘图提示词」页里手动编辑的内容',
        onTap: () => notifier.updateConfig(
          config.copyWith(clearSelectedSystemPromptPreset: true),
        ),
      ),
      for (final preset in config.systemPromptPresets)
        MoeSheetAction(
          icon: config.selectedSystemPromptPresetName == preset.name
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: preset.name,
          subtitle: _shortPreview(preset.content),
          onTap: () => notifier.updateConfig(
            config.copyWith(selectedSystemPromptPresetName: preset.name),
          ),
        ),
    ];

    await showMoeActionSheet(
      context: context,
      title: '选择生图提示词预设',
      actions: actions,
    );
  }

  Future<void> _showSizePicker({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
  }) async {
    const options = <List<int>>[
      [512, 512],
      [768, 768],
      [1024, 1024],
      [1216, 832],
      [832, 1216],
    ];

    var showCustom = false;

    await showMoeActionSheet(
      context: context,
      title: '选择默认尺寸',
      actions: [
        for (final option in options)
          MoeSheetAction(
            label: '${option[0]} x ${option[1]}',
            onTap: () async {
              await notifier.setDefaultWidth(option[0]);
              await notifier.setDefaultHeight(option[1]);
            },
          ),
        MoeSheetAction(
          label: '自定义尺寸...',
          onTap: () => showCustom = true,
        ),
      ],
    );

    if (showCustom && context.mounted) {
      await _showCustomSizeDialog(context: context, notifier: notifier);
    }
  }

  Future<void> _showCustomSizeDialog({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
  }) async {
    final currentState = notifier.debugState;
    final widthController =
        TextEditingController(text: '${currentState.defaultWidth}');
    final heightController =
        TextEditingController(text: '${currentState.defaultHeight}');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义尺寸'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: widthController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '宽度',
                  hintText: '256-2048',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('x'),
            ),
            Expanded(
              child: TextField(
                controller: heightController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '高度',
                  hintText: '256-2048',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final w = int.tryParse(widthController.text.trim());
      final h = int.tryParse(heightController.text.trim());
      if (w != null && h != null) {
        await notifier.setDefaultWidth(w);
        await notifier.setDefaultHeight(h);
      } else {
        if (context.mounted) MoeToast.warning(context, '请输入有效的数字');
      }
    }

    widthController.dispose();
    heightController.dispose();
  }

  Future<void> _showStepsPicker({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
    required int current,
  }) async {
    const options = <int>[20, 28, 35, 50];
    await showMoeActionSheet(
      context: context,
      title: '选择默认步数',
      actions: [
        for (final value in options)
          MoeSheetAction(
            icon: value == current ? Icons.check_circle : Icons.circle_outlined,
            label: '$value',
            onTap: () => notifier.setDefaultSteps(value),
          ),
      ],
    );
  }

  Future<void> _showGuidancePicker({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
    required double current,
  }) async {
    const options = <double>[3.5, 5.0, 7.0, 9.0];
    await showMoeActionSheet(
      context: context,
      title: '选择默认提示词强度',
      actions: [
        for (final value in options)
          MoeSheetAction(
            icon: value == current ? Icons.check_circle : Icons.circle_outlined,
            label: value.toStringAsFixed(1),
            onTap: () => notifier.setDefaultGuidanceScale(value),
          ),
      ],
    );
  }

  Future<void> _showCountPicker({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
    required int current,
  }) async {
    const options = <int>[1, 2, 3, 4];
    await showMoeActionSheet(
      context: context,
      title: '选择默认生成张数',
      actions: [
        for (final value in options)
          MoeSheetAction(
            icon: value == current ? Icons.check_circle : Icons.circle_outlined,
            label: '$value 张',
            onTap: () => notifier.setDefaultCount(value),
          ),
      ],
    );
  }

  Future<void> _editNegativePrompt({
    required BuildContext context,
    required ImagePluginConfigNotifier notifier,
    required String current,
  }) async {
    final controller = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('默认负面提示词'),
          content: TextField(
            controller: controller,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '例如：lowres, blurry, watermark',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      await notifier.setDefaultNegativePrompt(controller.text);
    }
    controller.dispose();
  }

  String _buildPromptSummary(ImageConfig config) {
    final systemPart = config.selectedSystemPromptPreset != null
        ? '系统：${config.selectedSystemPromptPreset!.name}'
        : (config.drawingSystemPrompt == ImageConfig.defaultDrawingSystemPrompt
            ? '系统：手动默认'
            : '系统：手动自定义');
    final artistPart = config.selectedArtistPreset != null
        ? ' / 画师串：${config.selectedArtistPreset!.name}'
        : '';
    return '$systemPart$artistPart';
  }

  String _shortPreview(String text) {
    final normalized = text.replaceAll('\n', ' ').trim();
    if (normalized.length <= 28) return normalized;
    return '${normalized.substring(0, 28)}...';
  }
}

/// 图片模型条目
class _ImageModelEntry {
  final String modelRef;
  final String modelId;
  final String providerId;
  final String providerName;
  final String displayName;

  const _ImageModelEntry({
    required this.modelRef,
    required this.modelId,
    required this.providerId,
    required this.providerName,
    required this.displayName,
  });
}
