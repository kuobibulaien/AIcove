import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  一级页面：画师串预设列表 + 预览
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class ArtistPresetPage extends ConsumerStatefulWidget {
  const ArtistPresetPage({super.key});

  @override
  ConsumerState<ArtistPresetPage> createState() => _ArtistPresetPageState();
}

class _ArtistPresetPageState extends ConsumerState<ArtistPresetPage> {
  bool _previewExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final config = ref.watch(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '画师串预设',
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

  // ━━━━━ 预设槽位列表 ━━━━━

  Widget _buildSlotSection(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
  ) {
    final colors = context.moeColors;
    final selectedName = config.selectedArtistPresetName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '画师串方案',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: MoeSpacing.xxs),
        Text(
          '选中的画师串会拼在正面提示词前面，负面部分会合并到负面提示词',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: MoeSpacing.sm),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            // 「不使用」选项
            MoeSettingsRow(
              icon: selectedName == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '不使用画师串',
              subtitle: '由 AI 自行决定全部提示词',
              trailingType: MoeSettingsRowTrailing.none,
              onTap: () => notifier.selectArtistPreset(null),
              showDivider: true,
            ),
            // 各个预设
            for (var i = 0; i < config.artistPresets.length; i++)
              _slotRow(context, config, notifier, i, selectedName),
            // 添加按钮
            MoeSettingsRow(
              icon: Icons.add_circle_outline,
              label: '添加画师串',
              subtitle: '新建一个空白画师串预设',
              trailingType: MoeSettingsRowTrailing.none,
              onTap: () => _addPreset(context, config, notifier),
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
    final preset = config.artistPresets[index];
    final isSelected = preset.name == selectedName;

    return MoeSettingsRow(
      icon: isSelected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: _presetPreview(preset),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: colors.muted),
        onPressed: () =>
            _showSlotActions(context, config, notifier, preset, index),
      ),
      onTap: () => notifier.selectArtistPreset(preset.name),
      showDivider: true,
    );
  }

  String _presetPreview(ArtistPreset preset, {int max = 42}) {
    final pos = preset.content.trim();
    final preview = pos.length > max ? '${pos.substring(0, max)}...' : pos;
    if (preview.isEmpty) return '(空)';
    return preview;
  }

  // ━━━━━ 只读预览 ━━━━━

  Widget _buildPreviewSection(BuildContext context, ImageConfig config) {
    final colors = context.moeColors;
    final preset = config.selectedArtistPreset;
    final previewText = preset != null
        ? _buildFullPreview(preset)
        : '当前未选择画师串，不会自动拼接';

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
                      top: Radius.circular(MoeSmoothRadii.sm))
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
                AnimatedRotation(
                  turns: _previewExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.keyboard_arrow_down,
                      size: 20, color: colors.muted),
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
                MoeSpacing.md, 0, MoeSpacing.md, MoeSpacing.md),
            decoration: BoxDecoration(
              color: colors.componentBackground,
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(MoeSmoothRadii.sm)),
            ),
            child: SelectableText(
              previewText,
              style: TextStyle(
                color: colors.text.withOpacity(0.8),
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

  String _buildFullPreview(ArtistPreset preset) {
    final buf = StringBuffer();
    buf.writeln('[ 正面提示词（拼在 prompt 前面） ]');
    buf.writeln(preset.content.trim().isEmpty ? '(空)' : preset.content.trim());
    buf.writeln();
    buf.writeln('[ 负面提示词（合并到 negative prompt） ]');
    buf.writeln(preset.negativeContent.trim().isEmpty
        ? '(空)'
        : preset.negativeContent.trim());
    return buf.toString().trimRight();
  }

  // ━━━━━ 弹窗 / 操作 ━━━━━

  void _openEditor(BuildContext context, String presetName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArtistPresetEditorPage(presetName: presetName),
      ),
    );
  }

  Future<void> _addPreset(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
  ) async {
    final name = await _showNameDialog(
      context: context,
      title: '新建画师串',
      hintText: '输入预设名称',
    );
    if (!mounted || name == null) return;
    if (config.artistPresets.any((p) => p.name == name)) {
      MoeToast.warning(this.context, '已存在同名预设');
      return;
    }
    await notifier.addArtistPreset(ArtistPreset(name: name, content: ''));
    await notifier.selectArtistPreset(name);
    if (!mounted) return;
    MoeToast.success(this.context, '已创建「$name」');
    _openEditor(this.context, name);
  }

  Future<void> _showSlotActions(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
    int index,
  ) async {
    final isBuiltin = index == 0 && ImageConfig.defaultArtistPresets
        .any((d) => d.name == preset.name);

    await showMoeActionSheet(
      context: context,
      title: preset.name,
      description: _presetPreview(preset, max: 90),
      actions: [
        MoeSheetAction(
          icon: Icons.edit_note_outlined,
          label: '编辑',
          onTap: () => _openEditor(context, preset.name),
        ),
        if (!isBuiltin)
          MoeSheetAction(
            icon: Icons.drive_file_rename_outline,
            label: '重命名',
            onTap: () => _renamePreset(context, config, notifier, preset),
          ),
        if (!isBuiltin)
          MoeSheetAction(
            icon: Icons.delete_outline,
            label: '删除',
            isDestructive: true,
            onTap: () => notifier.removeArtistPreset(preset.name),
          ),
      ],
    );
  }

  Future<void> _renamePreset(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
  ) async {
    final name = await _showNameDialog(
      context: context,
      title: '重命名画师串',
      hintText: '输入新名称',
      initial: preset.name,
    );
    if (!mounted || name == null) return;
    if (config.artistPresets
        .any((p) => p.name == name && p.name != preset.name)) {
      MoeToast.warning(this.context, '已存在同名预设');
      return;
    }
    await notifier.updateArtistPreset(
      preset.name,
      ArtistPreset(
        name: name,
        content: preset.content,
        negativeContent: preset.negativeContent,
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  二级页面：编辑某个画师串的正面 + 负面内容
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _ArtistPresetEditorPage extends ConsumerStatefulWidget {
  final String presetName;
  const _ArtistPresetEditorPage({required this.presetName});

  @override
  ConsumerState<_ArtistPresetEditorPage> createState() =>
      _ArtistPresetEditorPageState();
}

class _ArtistPresetEditorPageState
    extends ConsumerState<_ArtistPresetEditorPage> {
  late final TextEditingController _positiveCtrl;
  late final TextEditingController _negativeCtrl;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final preset = _findPreset();
    _positiveCtrl = TextEditingController(text: preset?.content ?? '');
    _negativeCtrl = TextEditingController(text: preset?.negativeContent ?? '');
    _positiveCtrl.addListener(_onChanged);
    _negativeCtrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _positiveCtrl.removeListener(_onChanged);
    _negativeCtrl.removeListener(_onChanged);
    _positiveCtrl.dispose();
    _negativeCtrl.dispose();
    super.dispose();
  }

  ArtistPreset? _findPreset() {
    final config = ref.read(imagePluginConfigProvider);
    return config.artistPresets
        .where((p) => p.name == widget.presetName)
        .firstOrNull;
  }

  void _onChanged() {
    final preset = _findPreset();
    if (preset == null) return;
    final dirty = preset.content != _positiveCtrl.text ||
        preset.negativeContent != _negativeCtrl.text;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _save() async {
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    await notifier.updateArtistPreset(
      widget.presetName,
      ArtistPreset(
        name: widget.presetName,
        content: _positiveCtrl.text,
        negativeContent: _negativeCtrl.text,
      ),
    );
    setState(() => _dirty = false);
    if (mounted) MoeToast.success(context, '已保存');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
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
          _fieldCard(
            context,
            title: '正面提示词（画师串）',
            hint: '自动拼在 AI 生成的 prompt 前面，一般是画师权重标签',
            controller: _positiveCtrl,
          ),
          const SizedBox(height: MoeSpacing.sm),
          _fieldCard(
            context,
            title: '负面提示词',
            hint: '自动合并到 negative prompt，常用质量控制标签',
            controller: _negativeCtrl,
          ),
          const SizedBox(height: MoeSpacing.lg),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _dirty ? _save : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(MoeSmoothRadii.sm),
                ),
              ),
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldCard(
    BuildContext context, {
    required String title,
    required String hint,
    required TextEditingController controller,
  }) {
    final colors = context.moeColors;
    return Container(
      padding: const EdgeInsets.all(MoeSpacing.sm),
      decoration: BoxDecoration(
        color: colors.componentBackground,
        borderRadius: BorderRadius.circular(MoeSmoothRadii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.text,
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
            ),
          ),
          const SizedBox(height: 2),
          Text(hint, style: TextStyle(color: colors.muted, fontSize: 11)),
          const SizedBox(height: MoeSpacing.xs),
          TextField(
            controller: controller,
            maxLines: null,
            minLines: 3,
            style: TextStyle(color: colors.text, fontSize: 13, height: 1.5),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: MoeSpacing.sm,
                vertical: MoeSpacing.xs,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.borderLight),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.borderLight),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colors.primary),
              ),
              filled: true,
              fillColor: colors.surface,
            ),
          ),
        ],
      ),
    );
  }
}
