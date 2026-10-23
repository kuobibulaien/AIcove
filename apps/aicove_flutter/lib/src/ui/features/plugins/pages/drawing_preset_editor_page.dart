import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/image_providers/comfyui_image_adapter.dart';
import '../../../../core/api/image_providers/comfyui_workflow.dart';
import '../../../../core/api/image_providers/image_provider_adapter_factory.dart';
import '../../../../features/chat/id_gen.dart';
import '../../../../features/plugins/image/drawing_parameters.dart';
import '../../../../features/plugins/image/drawing_preset.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/prompts/plugin_prompt_resolution.dart';
import '../../../../features/plugins/prompts/prompt_pack.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../settings/widgets/comfyui_workflow_editor.dart';
import '../widgets/preset_prompt_group.dart';
import 'image_generation_test_page.dart';

class DrawingPresetEditorPage extends ConsumerStatefulWidget {
  final DrawingPreset preset;
  final bool isNew;
  const DrawingPresetEditorPage({
    super.key,
    required this.preset,
    this.isNew = false,
  });
  @override
  ConsumerState<DrawingPresetEditorPage> createState() =>
      _DrawingPresetEditorPageState();
}

class _DrawingPresetEditorPageState
    extends ConsumerState<DrawingPresetEditorPage>
    with MoeAutoSaveState<DrawingPresetEditorPage> {
  final _fields = <String, TextEditingController>{};
  late ImageConfig _config;
  late PresetPromptBinding _prompts;
  late final String _presetId;
  bool _deleted = false;
  int _comfyFetchSeq = 0;

  @override
  void initState() {
    super.initState();
    _config = widget.preset.config;
    _prompts = widget.preset.prompts;
    _presetId = widget.isNew ? genId('drawing') : widget.preset.id;
    final values = <String, String>{
      'name': widget.isNew ? '${widget.preset.name}副本' : widget.preset.name,
      'style': _config.selectedArtistPreset?.content ?? '',
      'negativeStyle': _config.selectedArtistPreset?.negativeContent ?? '',
      'negative': _config.defaultNegativePrompt,
      'width': '${_config.defaultWidth}',
      'height': '${_config.defaultHeight}',
      'steps': '${_config.defaultSteps}',
      'guidance_scale': '${_config.defaultGuidanceScale}',
      'count': '${_config.defaultCount}',
      'timeout': '${_config.timeoutSeconds}',
      'lora_name': _config.comfyLoraName ?? '',
      'lora_strength': '${_config.comfyLoraStrength}',
    };
    for (final entry in values.entries) {
      _fields[entry.key] = TextEditingController(text: entry.value);
    }
    autoSave.configure(
      save: () async {
        final settings = ref.read(appSettingsProvider).valueOrNull;
        if (settings == null) throw const FormatException('请等待设置加载完成');
        await _save(settings);
      },
      snapshot: () => moeAutoSaveSignature([
        _config.toJson(),
        _prompts.toJson(),
        for (final c in _fields.values) c.text,
      ]),
      fields: _fields.values,
    );
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _text(String key) => _fields[key]!.text.trim();

  /// A modal-comfy gateway template keeps its own tuned sampling settings.
  bool _usesGatewayTemplate(String rawModelId, String comfyMode) =>
      ComfyUIWorkflow.isTemplateModel(rawModelId) &&
      comfyMode != ComfyUIWorkflow.customMode;

  Widget _field(
    String key,
    String label, {
    bool number = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: MoeTextField(
      controller: _fields[key],
      label: label,
      maxLines: lines,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.multiline,
    ),
  );

  /// Builds and validates the current [ImageConfig] from the form fields.
  /// Only validates fields that belong to the active provider and workflow mode.
  ImageConfig _buildValidatedConfig(AppSettings settings) {
    if (_text('name').isEmpty) throw const FormatException('请填写预设名称');
    final provider = settings.providers
        .where((p) => p.id == _config.selectedProviderId)
        .firstOrNull;
    final modelId = _config.selectedModelId == null
        ? null
        : settings.getRawModelId(_config.selectedModelId!);
    if (provider == null ||
        !provider.enabled ||
        modelId == null ||
        !settings
            .getProviderVisibleModelsByType(provider.id, type: ModelType.image)
            .contains(modelId)) {
      throw const FormatException('请重新选择可用的绘图渠道和模型');
    }
    final resolvedProvider = ImageProviderAdapterFactory.resolveProvider(
      provider.id,
      customConfig: provider.customConfig,
    );
    final novelAi = resolvedProvider == 'novelai';
    final isComfyUI = resolvedProvider == 'comfyui';
    final effectiveComfyMode = isComfyUI
        ? _config.effectiveComfyWorkflowMode(
            modelId: modelId,
            providerCustomConfig: provider.customConfig,
          )
        : ComfyUIWorkflow.inheritMode;
    final sampling =
        novelAi ||
        (isComfyUI &&
            !_usesGatewayTemplate(
              settings.getRawModelId(modelId),
              effectiveComfyMode,
            ));
    final args = <String, dynamic>{
      for (final key in ['width', 'height', 'count']) key: _text(key),
      if (sampling) ...{
        'steps': _text('steps'),
        'guidance_scale': _text('guidance_scale'),
      },
    };
    final values = DrawingParameters.resolve(
      _config,
      args,
      novelAi: novelAi,
      supportsSamplingParameters: sampling,
    );
    final timeout = int.tryParse(_text('timeout'));
    if (timeout == null || timeout < 5 || timeout > 600) {
      throw const FormatException('超时请填写 5–600 秒');
    }

    final isStandardComfy =
        isComfyUI && effectiveComfyMode == ComfyUIWorkflow.standardMode;

    final loraName = _text('lora_name');
    final loraStrength = double.tryParse(_text('lora_strength'));
    if (isStandardComfy &&
        loraName.isNotEmpty &&
        (loraStrength == null ||
            !loraStrength.isFinite ||
            loraStrength < -2 ||
            loraStrength > 2)) {
      throw const FormatException('LoRA 强度请填写 -2.0 到 2.0 之间的数值');
    }

    final style = ArtistPreset(
      name: '预设风格',
      content: _text('style'),
      negativeContent: _text('negativeStyle'),
    );
    final nextConfig = _config.copyWith(
      defaultWidth: values.width,
      defaultHeight: values.height,
      defaultCount: values.count,
      defaultSteps: values.steps,
      defaultGuidanceScale: values.guidanceScale,
      defaultNegativePrompt: _text('negative'),
      timeoutSeconds: timeout,
      artistPresets: [style],
      selectedArtistPresetName: style.name,
      comfyLoraName: isStandardComfy
          ? (loraName.isEmpty ? null : loraName)
          : _config.comfyLoraName,
      clearComfyLoraName: isStandardComfy && loraName.isEmpty,
      comfyLoraStrength: isStandardComfy
          ? (loraStrength ?? 1.0)
          : _config.comfyLoraStrength,
    );
    if (isComfyUI) {
      nextConfig.validateComfyConfiguration(
        modelId: modelId,
        providerCustomConfig: provider.customConfig,
      );
    }
    return nextConfig;
  }

  Future<void> _save(AppSettings settings) async {
    if (_deleted) return;
    final config = _buildValidatedConfig(settings);
    _config = config;
    final preset = DrawingPreset(
      id: _presetId,
      name: _text('name'),
      config: config,
      prompts: _prompts,
    );
    await ref.read(drawingPresetCatalogProvider.notifier).savePreset(preset);
  }

  Future<void> _pickModel(AppSettings settings) async {
    final entries = [
      for (final provider in settings.providers.where((p) => p.enabled))
        for (final model in settings.getProviderVisibleModelsByType(
          provider.id,
          type: ModelType.image,
        ))
          (provider: provider, model: model),
    ];
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择绘图渠道与模型',
      showCloseButton: true,
      maxHeight: MediaQuery.sizeOf(context).height * .7,
      builder: (ctx) => entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('暂无绘图模型，请先在渠道管理中添加并显示生图模型。'),
              ),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final entry = entries[i];
                final modelRef = settings.buildModelRef(
                  entry.provider.id,
                  entry.model,
                );
                return ListTile(
                  title: Text(settings.getModelDisplayName(modelRef)),
                  subtitle: Text(
                    '${entry.provider.displayName ?? entry.provider.id} / ${entry.model}',
                  ),
                  selected: modelRef == _config.selectedModelId,
                  onTap: () => Navigator.pop(ctx, modelRef),
                );
              },
            ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _config = _config.copyWith(
        selectedModelId: selected,
        selectedProviderId: settings.getModelProviderId(selected),
      );
    });
  }

  /// Fetches one option list from the ComfyUI server and lets the user pick.
  /// Returns `''` for the empty choice and null when cancelled or stale.
  Future<String?> _pickComfyOption(
    ProviderAuth provider, {
    required String title,
    required String label,
    required String emptyLabel,
    required String current,
    required Future<List<String>> Function({
      required String baseUrl,
      String apiKey,
    })
    fetch,
  }) async {
    final reqSeq = ++_comfyFetchSeq;
    final requestedProviderId = provider.id;
    bool stale() =>
        !mounted ||
        reqSeq != _comfyFetchSeq ||
        _config.selectedProviderId != requestedProviderId;

    List<String> options;
    try {
      options = await fetch(
        baseUrl: provider.apiBaseUrl,
        apiKey: provider.apiKeys.isNotEmpty
            ? provider.apiKeys.first.trim()
            : '',
      );
    } catch (error) {
      if (mounted && !stale()) {
        MoeToast.error(context, '拉取$label列表失败：$error');
      }
      return null;
    }
    if (!mounted || stale()) return null;
    if (options.isEmpty) {
      MoeToast.warning(context, '服务端未返回可用$label');
      return null;
    }
    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: title,
      showCloseButton: true,
      maxHeight: MediaQuery.sizeOf(context).height * .7,
      builder: (ctx) => ListView.builder(
        shrinkWrap: true,
        itemCount: options.length + 1,
        itemBuilder: (_, i) {
          final item = i == 0 ? '' : options[i - 1];
          return ListTile(
            title: Text(i == 0 ? emptyLabel : item),
            selected: item == current,
            onTap: () => Navigator.pop(ctx, item),
          );
        },
      ),
    );
    return selected == null || stale() ? null : selected;
  }

  Future<void> _pickLora(ProviderAuth provider) async {
    final selected = await _pickComfyOption(
      provider,
      title: '选择 LoRA 模型',
      label: ' LoRA ',
      emptyLabel: '不使用 LoRA',
      current: _text('lora_name'),
      fetch: ComfyUIImageAdapter.fetchLoras,
    );
    if (selected == null) return;
    setState(() => _fields['lora_name']!.text = selected);
  }

  Future<void> _pickSampler(ProviderAuth provider, String emptyLabel) async {
    final selected = await _pickComfyOption(
      provider,
      title: '选择采样器',
      label: '采样器',
      emptyLabel: emptyLabel,
      current: _config.comfySampler ?? '',
      fetch: ComfyUIImageAdapter.fetchSamplers,
    );
    if (selected == null) return;
    setState(() {
      _config = _config.copyWith(
        comfySampler: selected,
        clearComfySampler: selected.isEmpty,
      );
    });
  }

  Future<void> _pickScheduler(ProviderAuth provider, String emptyLabel) async {
    final selected = await _pickComfyOption(
      provider,
      title: '选择调度器',
      label: '调度器',
      emptyLabel: emptyLabel,
      current: _config.comfyScheduler ?? '',
      fetch: ComfyUIImageAdapter.fetchSchedulers,
    );
    if (selected == null) return;
    setState(() {
      _config = _config.copyWith(
        comfyScheduler: selected,
        clearComfyScheduler: selected.isEmpty,
      );
    });
  }

  Future<void> _editPresetWorkflow(ProviderAuth? provider) async {
    final initial =
        _config.comfyWorkflowConfig ??
        (provider != null &&
                ComfyUIWorkflow.hasCustomWorkflow(provider.customConfig)
            ? <String, dynamic>{
                for (final key in [
                  ComfyUIWorkflow.workflowKey,
                  ComfyUIWorkflow.bindingsKey,
                  ComfyUIWorkflow.outputKey,
                ])
                  if (provider.customConfig.containsKey(key))
                    key: provider.customConfig[key],
              }
            : const <String, dynamic>{});
    final updated = await showComfyUIWorkflowEditor(context, initial);
    if (updated == null || !mounted) return;
    setState(() {
      _config = _config.copyWith(
        comfyWorkflowConfig: updated,
        comfyWorkflowMode: ComfyUIWorkflow.customMode,
      );
    });
  }

  void _restoreStandardMode(AppSettings settings, ProviderAuth provider) {
    final currentRawModel = _config.selectedModelId == null
        ? ''
        : settings.getRawModelId(_config.selectedModelId!);
    var nextModelRef = _config.selectedModelId;
    if (currentRawModel.isEmpty || currentRawModel == ComfyUIWorkflow.modelId) {
      final candidate = settings
          .getProviderVisibleModelsByType(provider.id, type: ModelType.image)
          .where((m) => m != ComfyUIWorkflow.modelId)
          .firstOrNull;
      if (candidate != null) {
        nextModelRef = settings.buildModelRef(provider.id, candidate);
      } else {
        MoeToast.warning(context, '请先选择具体的 ComfyUI 基础模型');
      }
    }
    setState(() {
      _config = _config.copyWith(
        selectedModelId: nextModelRef,
        clearComfyWorkflowConfig: true,
        comfyWorkflowMode: ComfyUIWorkflow.standardMode,
      );
    });
  }

  void _test(BuildContext context) {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    var testConfig = _config;
    if (settings != null) {
      try {
        testConfig = _buildValidatedConfig(settings);
        _config = testConfig;
      } on FormatException catch (error) {
        MoeToast.error(context, error.message);
        return;
      } catch (error) {
        MoeToast.error(context, '$error');
        return;
      }
    }
    Navigator.push(
      context,
      ParallaxSlidePageRoute(
        page: ImageGenerationTestPage(
          drawingConfig: testConfig,
          initialModelLabel: _text('name').isNotEmpty
              ? _text('name')
              : widget.preset.name,
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    Navigator.push(
      context,
      ParallaxSlidePageRoute(
        page: DrawingPresetEditorPage(
          preset: widget.preset.copyWith(
            name: '${_text('name')}副本',
            config: _config,
          ),
          isNew: true,
        ),
      ),
    );
  }

  Future<void> _setDefault(BuildContext context) async {
    try {
      await ref
          .read(drawingPresetCatalogProvider.notifier)
          .setDefault(widget.preset.id);
      if (context.mounted) MoeToast.success(context, '已设为默认预设');
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '设为默认失败：$e');
    }
  }

  Future<void> _delete(BuildContext context) async {
    final catalog = ref.read(drawingPresetCatalogProvider).valueOrNull;
    if (catalog != null && widget.preset.id == catalog.defaultPresetId) {
      MoeToast.error(context, '这是默认绘图预设，请先将其他预设设为默认');
      return;
    }
    final confirmed = await showMeoTalkDialog(
      context: context,
      title: '删除绘图预设？',
      content: Text(
        '确定删除「${_text('name').isNotEmpty ? _text('name') : widget.preset.name}」？删除后无法恢复。仍有角色使用的预设不会被删除。',
      ),
      cancelText: '取消',
      confirmText: '删除',
      isDanger: true,
    );
    if (confirmed != true || !context.mounted) return;
    try {
      _deleted = true;
      await ref
          .read(drawingPresetCatalogProvider.notifier)
          .deletePreset(widget.preset.id);
      if (context.mounted) {
        MoeToast.success(context, '绘图预设已删除');
        Navigator.pop(context);
      }
    } catch (e) {
      _deleted = false;
      if (context.mounted) MoeToast.error(context, '删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final catalog = ref.watch(drawingPresetCatalogProvider).valueOrNull;
    final isDefault = catalog?.defaultPresetId == widget.preset.id;
    final colors = context.moeColors;

    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: widget.isNew ? '新建绘图预设' : '编辑绘图预设',
          showBackButton: true,
          actions: [
            MoeIconButton(
              icon: Icons.play_circle_outline,
              tooltip: '生图测试',
              onTap: () => _test(context),
            ),
            if (!widget.isNew)
              MoeIconButton(
                icon: Icons.copy_outlined,
                tooltip: '复制预设',
                onTap: () => _copy(context),
              ),
          ],
        ),
        body: settingsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败：$e')),
          data: (settings) {
            final provider = settings.providers
                .where((p) => p.id == _config.selectedProviderId)
                .firstOrNull;
            final novelAi =
                provider != null &&
                ImageProviderAdapterFactory.resolveProvider(
                      provider.id,
                      customConfig: provider.customConfig,
                    ) ==
                    'novelai';
            final isComfyUI =
                provider != null &&
                ImageProviderAdapterFactory.resolveProvider(
                      provider.id,
                      customConfig: provider.customConfig,
                    ) ==
                    'comfyui';
            final rawModelId = _config.selectedModelId == null
                ? ''
                : settings.getRawModelId(_config.selectedModelId!);
            final effectiveComfyMode = isComfyUI
                ? _config.effectiveComfyWorkflowMode(
                    modelId: rawModelId,
                    providerCustomConfig: provider.customConfig,
                  )
                : ComfyUIWorkflow.inheritMode;
            final hasCustomWorkflow =
                isComfyUI && effectiveComfyMode == ComfyUIWorkflow.customMode;
            final gatewayTemplate =
                isComfyUI &&
                _usesGatewayTemplate(rawModelId, effectiveComfyMode);
            final sampling = novelAi || (isComfyUI && !gatewayTemplate);
            final comfyDefaultSampler = hasCustomWorkflow
                ? '沿用工作流'
                : '默认（${ComfyUIWorkflow.defaultSampler}）';
            final comfyDefaultScheduler = hasCustomWorkflow
                ? '沿用工作流'
                : '默认（${ComfyUIWorkflow.defaultScheduler}）';
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Builder(
                  builder: (context) => ListView(
                    padding: moeUnderBarPadding(
                      context,
                      const EdgeInsets.all(16),
                    ),
                    children: [
                      _field('name', '预设名称'),
                      MoeSettingsGroup(
                        margin: const EdgeInsets.only(bottom: 16),
                        children: [
                          MoeSettingsRow(
                            label: '渠道与模型',
                            subtitle: _config.selectedModelId == null
                                ? '请选择'
                                : '${provider?.displayName ?? provider?.id ?? '渠道不可用'}\n${settings.getModelDisplayName(_config.selectedModelId!)}',
                            onTap: () => _pickModel(settings),
                          ),
                          if (!widget.isNew) ...[
                            if (isDefault)
                              MoeSettingsRow(
                                icon: Icons.check_circle,
                                iconColor: colors.primary,
                                label: '默认预设',
                                subtitle: '当前角色未单独绑定时使用此预设',
                                trailingType: MoeSettingsRowTrailing.none,
                              )
                            else
                              MoeSettingsRow(
                                label: '设为默认预设',
                                subtitle: '未单独绑定预设的角色将使用此预设',
                                trailingType: MoeSettingsRowTrailing.chevron,
                                onTap: () => _setDefault(context),
                              ),
                          ],
                        ],
                      ),
                      if (isComfyUI) ...[
                        MoeSettingsGroup(
                          title: 'ComfyUI 工作流',
                          margin: const EdgeInsets.only(bottom: 16),
                          children: [
                            MoeSettingsRow(
                              label: '工作流模式',
                              subtitle: hasCustomWorkflow
                                  ? '自定义 JSON 工作流（已导入并绑定）'
                                  : gatewayTemplate
                                  ? '服务端模板 ${ComfyUIWorkflow.templateName(rawModelId)}（步数、提示词强度和采样器由模板决定）'
                                  : '标准基础模型工作流（支持直接附加 LoRA）',
                              detailText: hasCustomWorkflow
                                  ? '编辑 JSON'
                                  : '导入 JSON',
                              trailingType: MoeSettingsRowTrailing.text,
                              onTap: () => _editPresetWorkflow(provider),
                            ),
                            if (!gatewayTemplate) ...[
                              MoeSettingsRow(
                                label: '采样器',
                                subtitle:
                                    _config.comfySampler ?? comfyDefaultSampler,
                                detailText: '拉取列表',
                                trailingType: MoeSettingsRowTrailing.text,
                                onTap: () =>
                                    _pickSampler(provider, comfyDefaultSampler),
                              ),
                              MoeSettingsRow(
                                label: '调度器',
                                subtitle:
                                    _config.comfyScheduler ??
                                    comfyDefaultScheduler,
                                detailText: '拉取列表',
                                trailingType: MoeSettingsRowTrailing.text,
                                onTap: () => _pickScheduler(
                                  provider,
                                  comfyDefaultScheduler,
                                ),
                              ),
                            ],
                            if (hasCustomWorkflow)
                              MoeSettingsRow(
                                label: '恢复标准模型模式',
                                subtitle: '清除自定义 JSON，改用所选基础模型与 LoRA',
                                trailingType: MoeSettingsRowTrailing.chevron,
                                onTap: () =>
                                    _restoreStandardMode(settings, provider),
                              )
                            else
                              MoeSettingsRow(
                                label: '从服务端选择 LoRA',
                                subtitle: _text('lora_name').isEmpty
                                    ? '可留空（仅使用基础模型）'
                                    : _text('lora_name'),
                                detailText: '拉取列表',
                                trailingType: MoeSettingsRowTrailing.text,
                                onTap: () => _pickLora(provider),
                              ),
                          ],
                        ),
                        if (!hasCustomWorkflow) ...[
                          _field(
                            'lora_name',
                            'LoRA 名称（可选，如 style_v1.safetensors）',
                          ),
                          _field(
                            'lora_strength',
                            'LoRA 强度（-2.0 到 2.0，默认 1.0）',
                            number: true,
                          ),
                        ],
                      ],
                      _field('style', '画师串 / 正面风格', lines: 4),
                      _field('negativeStyle', '负面风格', lines: 3),
                      const Text(
                        '参考参数',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      _field('width', '宽度（256–2048）', number: true),
                      _field('height', '高度（256–2048）', number: true),
                      if (sampling) ...[
                        _field('steps', '步数（1–100）', number: true),
                        _field('guidance_scale', '提示词强度（0–10）', number: true),
                      ],
                      _field('count', '张数（1–4）', number: true),
                      ExpansionTile(
                        title: const Text('高级'),
                        subtitle: const Text('负面提示词与请求超时'),
                        childrenPadding: const EdgeInsets.only(top: 16),
                        children: [
                          _field('negative', '基础负面提示词', lines: 3),
                          _field('timeout', '请求超时（5–600 秒）', number: true),
                        ],
                      ),
                      if (provider != null &&
                          _config.selectedModelId != null) ...[
                        const SizedBox(height: 16),
                        PresetPromptGroup(
                          pluginId: 'image',
                          binding: _prompts,
                          onChanged: (next) => setState(() => _prompts = next),
                          format: imagePromptFormat(
                            provider.id,
                            provider.customConfig,
                          ),
                          model: settings.getRawModelId(
                            _config.selectedModelId!,
                          ),
                          presetName: _text('name'),
                          variables: {
                            'default_width':
                                int.tryParse(_text('width')) ??
                                _config.defaultWidth,
                            'default_height':
                                int.tryParse(_text('height')) ??
                                _config.defaultHeight,
                            'default_count':
                                int.tryParse(_text('count')) ??
                                _config.defaultCount,
                            'default_steps':
                                int.tryParse(_text('steps')) ??
                                _config.defaultSteps,
                            'default_guidance_scale':
                                double.tryParse(_text('guidance_scale')) ??
                                _config.defaultGuidanceScale,
                          },
                        ),
                      ],
                      const SizedBox(height: 8),
                      MoeSecondaryButton(
                        label: '生图测试',
                        onPressed: () => _test(context),
                      ),
                      if (!widget.isNew) ...[
                        const SizedBox(height: 12),
                        MoeSecondaryButton(
                          key: ValueKey('delete-drawing-${widget.preset.id}'),
                          label: '删除预设',
                          foregroundColor: Theme.of(context).colorScheme.error,
                          onPressed: () => _delete(context),
                        ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
