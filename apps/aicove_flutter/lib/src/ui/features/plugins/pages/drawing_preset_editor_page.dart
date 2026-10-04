import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/chat/id_gen.dart';
import '../../../../features/plugins/image/drawing_parameters.dart';
import '../../../../features/plugins/image/drawing_preset.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/api/image_providers/image_provider_adapter_factory.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
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
  late final String _presetId;
  bool _deleted = false;

  @override
  void initState() {
    super.initState();
    _config = widget.preset.config;
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

  Future<void> _save(AppSettings settings) async {
    if (_deleted) return;
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
    final novelAi =
        ImageProviderAdapterFactory.resolveProvider(
          provider.id,
          customConfig: provider.customConfig,
        ) ==
        'novelai';
    final sampling =
        novelAi ||
        ImageProviderAdapterFactory.resolveProvider(
              provider.id,
              customConfig: provider.customConfig,
            ) ==
            'comfyui';
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
    final style = ArtistPreset(
      name: '预设风格',
      content: _text('style'),
      negativeContent: _text('negativeStyle'),
    );
    final config = _config.copyWith(
      defaultWidth: values.width,
      defaultHeight: values.height,
      defaultCount: values.count,
      defaultSteps: values.steps,
      defaultGuidanceScale: values.guidanceScale,
      defaultNegativePrompt: _text('negative'),
      timeoutSeconds: timeout,
      artistPresets: [style],
      selectedArtistPresetName: style.name,
    );
    final preset = DrawingPreset(
      id: _presetId,
      name: _text('name'),
      config: config,
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
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .7,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('选择绘图渠道与模型'),
              ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('暂无绘图模型，请先在渠道管理中添加并显示生图模型。'),
                        ),
                      )
                    : ListView.builder(
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
              ),
            ],
          ),
        ),
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

  void _test(BuildContext context) {
    Navigator.push(
      context,
      ParallaxSlidePageRoute(
        page: ImageGenerationTestPage(
          drawingConfig: _config,
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
          preset: widget.preset.copyWith(name: '${_text('name')}副本'),
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
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: '生图测试',
              onPressed: () => _test(context),
            ),
            if (!widget.isNew)
              IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: '复制预设',
                onPressed: () => _copy(context),
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
            final sampling =
                novelAi ||
                (provider != null &&
                    ImageProviderAdapterFactory.resolveProvider(
                          provider.id,
                          customConfig: provider.customConfig,
                        ) ==
                        'comfyui');
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Builder(
                  builder: (context) => ListView(
                    padding: moeUnderBarPadding(context, EdgeInsets.all(16)),
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
                      _field('style', '画师串 / 正面风格', lines: 4),
                      _field('negativeStyle', '负面风格', lines: 3),
                      const Text(
                        '参考参数',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('模型可按画面需要合理调整；未传参数时使用这里的值。'),
                      ),
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
                      const SizedBox(height: 24),
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
