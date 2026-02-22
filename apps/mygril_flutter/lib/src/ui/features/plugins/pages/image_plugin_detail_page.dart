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

    final imageProviders = _imageProviders(settings);
    final selectedProvider =
        _resolveSelectedProvider(config: config, providers: imageProviders);
    final availableModels = selectedProvider == null
        ? const <String>[]
        : _modelsOf(selectedProvider);
    final selectedModel = _resolveSelectedModel(
      config: config,
      provider: selectedProvider,
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
              icon: Icons.hub_outlined,
              label: selectedProvider == null
                  ? '自动选择可用渠道'
                  : (selectedProvider.displayName ?? selectedProvider.id),
              subtitle: imageProviders.isEmpty
                  ? '暂无可用图片渠道，请先到渠道商管理新增'
                  : '渠道来源：设置 - 渠道商管理',
              trailingType: MoeSettingsRowTrailing.chevron,
              onTap: imageProviders.isEmpty
                  ? () => MoeToast.show(context, '暂无可用图片渠道，请先到渠道商管理添加')
                  : () => _showProviderPicker(
                        context: context,
                        ref: ref,
                        providers: imageProviders,
                        config: config,
                      ),
            ),
            MoeSettingsRow(
              icon: Icons.auto_awesome_outlined,
              label: selectedModel ?? '自动选择首个模型',
              subtitle: selectedProvider == null
                  ? '请先选择渠道'
                  : (availableModels.isEmpty
                      ? '当前渠道暂无模型，请到渠道详情页添加'
                      : '模型来源：渠道商管理中的模型列表'),
              trailingType: MoeSettingsRowTrailing.chevron,
              enabled: selectedProvider != null,
              onTap: selectedProvider == null
                  ? null
                  : () => _showModelPicker(
                        context: context,
                        ref: ref,
                        provider: selectedProvider,
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
              subtitle: config.selectedArtistPreset != null
                  ? '画师串：${config.selectedArtistPreset!.name}'
                  : (config.drawingSystemPrompt ==
                          ImageConfig.defaultDrawingSystemPrompt
                      ? '使用默认 NovelAI 提示词规范'
                      : '已自定义'),
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

  List<ProviderAuth> _imageProviders(AppSettings settings) {
    return settings.providers.where((p) {
      if (!p.enabled) return false;
      final isImageType = p.modelType == 'image';
      final hasImageCapability = p.capabilities.contains('image');
      return isImageType || hasImageCapability;
    }).toList();
  }

  ProviderAuth? _resolveSelectedProvider({
    required ImageConfig config,
    required List<ProviderAuth> providers,
  }) {
    if (providers.isEmpty) return null;
    if (config.selectedProviderId != null &&
        config.selectedProviderId!.trim().isNotEmpty) {
      final selected =
          providers.where((p) => p.id == config.selectedProviderId).firstOrNull;
      if (selected != null) return selected;
    }
    return providers.first;
  }

  List<String> _modelsOf(ProviderAuth provider) {
    return provider.visibleModels.isNotEmpty
        ? provider.visibleModels
        : provider.models;
  }

  String? _resolveSelectedModel({
    required ImageConfig config,
    required ProviderAuth? provider,
  }) {
    if (provider == null) return null;
    final models = _modelsOf(provider);
    final selected = config.selectedModelId?.trim();
    if (selected != null && selected.isNotEmpty) {
      if (models.isEmpty || models.contains(selected)) return selected;
    }
    final fromCustom =
        provider.customConfig['defaultImageModel']?.toString().trim();
    if (fromCustom != null && fromCustom.isNotEmpty) return fromCustom;
    if (models.isNotEmpty) return models.first;
    return null;
  }

  Future<void> _showProviderPicker({
    required BuildContext context,
    required WidgetRef ref,
    required List<ProviderAuth> providers,
    required ImageConfig config,
  }) async {
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: config.selectedProviderId == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '自动选择',
        subtitle: '使用首个可用图片渠道',
        onTap: () => notifier.setSelectedProvider(null),
      ),
      for (final provider in providers)
        MoeSheetAction(
          icon: provider.id == config.selectedProviderId
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: provider.displayName ?? provider.id,
          subtitle: provider.id,
          onTap: () => notifier.setSelectedProvider(provider.id),
        ),
    ];

    await showMoeActionSheet(
      context: context,
      title: '选择绘图渠道',
      actions: actions,
    );
  }

  Future<void> _showModelPicker({
    required BuildContext context,
    required WidgetRef ref,
    required ProviderAuth provider,
    required ImageConfig config,
  }) async {
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    final models = _modelsOf(provider);
    if (models.isEmpty) {
      MoeToast.show(context, '当前渠道暂无模型，请先在渠道商管理添加');
      return;
    }

    final actions = <MoeSheetAction>[
      MoeSheetAction(
        icon: config.selectedModelId == null
            ? Icons.check_circle
            : Icons.circle_outlined,
        label: '自动选择',
        subtitle: '使用当前渠道第一个模型',
        onTap: () => notifier.setSelectedModel(null),
      ),
      for (final model in models)
        MoeSheetAction(
          icon: config.selectedModelId == model
              ? Icons.check_circle
              : Icons.circle_outlined,
          label: model,
          onTap: () => notifier.setSelectedModel(model),
        ),
    ];

    await showMoeActionSheet(
      context: context,
      title: '选择绘图模型',
      description: provider.displayName ?? provider.id,
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

}
