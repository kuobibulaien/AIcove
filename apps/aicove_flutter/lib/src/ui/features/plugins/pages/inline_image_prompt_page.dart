import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class InlineImagePromptPage extends ConsumerStatefulWidget {
  const InlineImagePromptPage({super.key});

  @override
  ConsumerState<InlineImagePromptPage> createState() =>
      _InlineImagePromptPageState();
}

class _InlineImagePromptPageState extends ConsumerState<InlineImagePromptPage> {
  bool _previewExpanded = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(imagePluginConfigProvider);
    final migrated = _migrateIfNeeded(config);
    if (migrated != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(imagePluginConfigProvider.notifier).updateConfig(migrated);
      });
    }
  }

  ImageConfig? _migrateIfNeeded(ImageConfig config) {
    if (config.selectedFastPromptPreset != null) {
      return null;
    }
    if (config.fastPromptPresets.isEmpty) {
      return config.copyWith(
        fastPromptPresets: ImageConfig.defaultInlinePromptPresets,
        selectedFastPromptPresetName:
            ImageConfig.defaultInlinePromptPresets.first.name,
      );
    }
    return config.copyWith(
      selectedFastPromptPresetName: config.fastPromptPresets.first.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final config = ref.watch(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '快速链路提示词模板',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          MoeSpacing.md,
          MoeSpacing.md,
          MoeSpacing.md,
          MoeSpacing.xl,
        ),
        children: [
          _buildSlotSection(context, config, notifier),
          const SizedBox(height: MoeSpacing.lg),
          _buildPreviewSection(context, config),
        ],
      ),
    );
  }

  Widget _buildSlotSection(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    final selectedName = config.selectedFastPromptPreset?.name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '预设方案',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: MoeSpacing.xxs),
        Text(
          '管理快速链路下注入给 <image> 的系统提示词模板',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: MoeSpacing.sm),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            for (var i = 0; i < config.fastPromptPresets.length; i++)
              _slotRow(context, config, notifier, i, selectedName),
            MoeSettingsRow(
              icon: Icons.add_circle_outline,
              label: '添加预设',
              subtitle: '复制当前选中预设的内容',
              trailingType: MoeSettingsRowTrailing.none,
              onTap: () => _addSlot(context, config, notifier),
              showDivider: false,
            ),
          ],
        ),
      ],
    );
  }

  Widget _slotRow(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    int index,
    String? selectedName,
  ) {
    final colors = context.moeColors;
    final preset = config.fastPromptPresets[index];
    final isSelected = preset.name == selectedName;

    return MoeSettingsRow(
      icon: isSelected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: config.buildInlinePresetPreview(preset),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: colors.muted),
        onPressed: () =>
            _showSlotActions(context, config, notifier, preset, index),
      ),
      onTap: () => notifier.updateConfig(
        config.copyWith(selectedFastPromptPresetName: preset.name),
      ),
      showDivider: true,
    );
  }

  Widget _buildPreviewSection(BuildContext context, ImageConfig config) {
    final colors = context.moeColors;
    final previewText = config.effectiveInlinePromptTemplate;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _previewExpanded = !_previewExpanded),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: MoeSpacing.md,
              vertical: MoeSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.componentBackground,
              borderRadius: _previewExpanded
                  ? const BorderRadius.vertical(
                      top: Radius.circular(MoeSmoothRadii.sm),
                    )
                  : BorderRadius.circular(MoeSmoothRadii.sm),
            ),
            child: Row(
              children: [
                Icon(Icons.preview_outlined, size: 20, color: colors.text),
                const SizedBox(width: MoeSpacing.xs),
                Expanded(
                  child: Text(
                    '当前生效内容预览',
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 15,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
                ),
                Text(
                  '${previewText.length} 字',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                const SizedBox(width: MoeSpacing.xxs),
                AnimatedRotation(
                  turns: _previewExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 20,
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
              MoeSpacing.md,
              0,
              MoeSpacing.md,
              MoeSpacing.md,
            ),
            decoration: BoxDecoration(
              color: colors.componentBackground,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(MoeSmoothRadii.sm),
              ),
            ),
            child: SelectableText(
              previewText,
              style: TextStyle(
                color: colors.text.withValues(alpha: 0.8),
                fontSize: 12,
                height: 1.6,
                fontFamily: 'monospace',
              ),
            ),
          ),
          crossFadeState: _previewExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
      ],
    );
  }

  Future<void> _addSlot(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
  ) async {
    final name = await _showNameDialog(
      context: context,
      title: '新建预设',
      hintText: '输入预设名称',
    );
    if (!mounted || name == null) return;
    if (config.fastPromptPresets.any((p) => p.name == name)) {
      MoeToast.warning(this.context, '已存在同名预设');
      return;
    }
    final preset = DrawingPromptPreset(
      name: name,
      content: config.effectiveInlinePromptTemplate,
    );
    await notifier.updateConfig(
      config.copyWith(
        fastPromptPresets: [...config.fastPromptPresets, preset],
        selectedFastPromptPresetName: name,
      ),
    );
    if (!mounted) return;
    MoeToast.success(this.context, '已创建「$name」');
  }

  Future<void> _showSlotActions(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
    int index,
  ) async {
    final isFirst = index == 0;

    await showMoeActionSheet(
      context: context,
      title: preset.name,
      description: config.buildInlinePresetPreview(preset, max: 90),
      actions: [
        MoeSheetAction(
          icon: Icons.edit_note_outlined,
          label: '编辑',
          onTap: () => _openEditor(context, preset.name),
        ),
        if (!isFirst)
          MoeSheetAction(
            icon: Icons.drive_file_rename_outline,
            label: '重命名',
            onTap: () => _renameSlot(context, config, notifier, preset),
          ),
        if (!isFirst)
          MoeSheetAction(
            icon: Icons.delete_outline,
            label: '删除',
            isDestructive: true,
            onTap: () => _deleteSlot(config, notifier, preset),
          ),
      ],
    );
  }

  void _openEditor(BuildContext context, String presetName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _InlinePromptEditorPage(presetName: presetName),
      ),
    );
  }

  Future<void> _renameSlot(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    final name = await _showNameDialog(
      context: context,
      title: '重命名预设',
      hintText: '输入新名称',
      initial: preset.name,
    );
    if (!mounted || name == null) return;
    if (config.fastPromptPresets
        .any((p) => p.name == name && p.name != preset.name)) {
      MoeToast.warning(this.context, '已存在同名预设');
      return;
    }
    final updated = config.fastPromptPresets
        .map((p) => p.name == preset.name
            ? DrawingPromptPreset(name: name, content: p.content)
            : p)
        .toList();
    await notifier.updateConfig(
      config.copyWith(
        fastPromptPresets: updated,
        selectedFastPromptPresetName:
            config.selectedFastPromptPresetName == preset.name
                ? name
                : config.selectedFastPromptPresetName,
      ),
    );
  }

  Future<void> _deleteSlot(
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    final updated =
        config.fastPromptPresets.where((p) => p.name != preset.name).toList();
    final wasSelected = config.selectedFastPromptPresetName == preset.name;
    await notifier.updateConfig(
      config.copyWith(
        fastPromptPresets: updated,
        selectedFastPromptPresetName:
            wasSelected && updated.isNotEmpty ? updated.first.name : null,
        clearSelectedFastPromptPreset: wasSelected && updated.isEmpty,
      ),
    );
  }

  Future<String?> _showNameDialog({
    required BuildContext context,
    required String title,
    required String hintText,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hintText,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }
}

class _InlinePromptEditorPage extends ConsumerStatefulWidget {
  const _InlinePromptEditorPage({required this.presetName});

  final String presetName;

  @override
  ConsumerState<_InlinePromptEditorPage> createState() =>
      _InlinePromptEditorPageState();
}

class _InlinePromptEditorPageState
    extends ConsumerState<_InlinePromptEditorPage> {
  late final TextEditingController _controller;
  bool _dirty = false;
  bool _allowNativePop = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(imagePluginConfigProvider);
    final text = _loadText(config);
    _controller = TextEditingController(text: text);
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  String _loadText(ImageConfig config) {
    final preset = config.fastPromptPresets
        .where((p) => p.name == widget.presetName)
        .firstOrNull;
    if (preset == null || preset.content.trim().isEmpty) {
      return ImageConfig.defaultInlinePromptTemplate;
    }
    return preset.content;
  }

  void _onChanged() {
    final saved = _loadText(ref.read(imagePluginConfigProvider));
    final dirty = saved.trim() != _controller.text.trim();
    if (dirty != _dirty) {
      setState(() => _dirty = dirty);
    }
  }

  Future<void> _save() async {
    final config = ref.read(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    final updated = config.fastPromptPresets.map((p) {
      if (p.name == widget.presetName) {
        return DrawingPromptPreset(
          name: p.name,
          content: _controller.text.trim(),
        );
      }
      return p;
    }).toList();
    await notifier.updateConfig(config.copyWith(fastPromptPresets: updated));
    setState(() => _dirty = false);
    if (mounted) MoeToast.success(context, '已保存');
  }

  Future<void> _handleBack() async {
    if (!_dirty) {
      _allowAndPop();
      return;
    }
    final result = await showMeoTalkDialog(
      context: context,
      title: '未保存的修改',
      content: const Text('当前有未保存的修改，是否保存？'),
      cancelText: '不保存',
      confirmText: '保存',
    );
    if (!mounted || result == null) return;
    if (result) {
      await _save();
    }
    _allowAndPop();
  }

  void _allowAndPop() {
    if (!_allowNativePop) {
      setState(() => _allowNativePop = true);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return PopScope(
      canPop: _allowNativePop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: '编辑「${widget.presetName}」',
          showBackButton: true,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            MoeSpacing.md,
            MoeSpacing.md,
            MoeSpacing.md,
            MoeSpacing.xl,
          ),
          children: [
            MoeSettingsGroup(
              title: '模板内容',
              margin: EdgeInsets.zero,
              children: [
                Padding(
                  padding: const EdgeInsets.all(MoeSpacing.md),
                  child: TextField(
                    controller: _controller,
                    maxLines: 18,
                    minLines: 12,
                    decoration: const InputDecoration(
                      hintText: '输入快速链路要注入的完整提示词模板',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: MoeSpacing.md),
            MoePrimaryButton(
              label: '保存',
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}
