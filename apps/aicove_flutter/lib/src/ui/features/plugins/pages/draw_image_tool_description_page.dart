import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  一级页面：预设槽位列表 + 只读预览
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class DrawImageToolDescriptionPage extends ConsumerStatefulWidget {
  const DrawImageToolDescriptionPage({super.key});

  @override
  ConsumerState<DrawImageToolDescriptionPage> createState() =>
      _DrawImageToolDescriptionPageState();
}

class _DrawImageToolDescriptionPageState
    extends ConsumerState<DrawImageToolDescriptionPage> {
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

  // ── 迁移：旧版 → 槽位模型 ──

  ImageConfig? _migrateIfNeeded(ImageConfig config) {
    var presets = List<DrawingPromptPreset>.from(config.systemPromptPresets);
    var selectedName = config.selectedSystemPromptPresetName;
    var needsUpdate = false;

    final oldIdx = presets.indexWhere((p) => p.name == '默认工具描述');
    if (oldIdx >= 0) {
      presets[oldIdx] = DrawingPromptPreset(
        name: '默认',
        content: presets[oldIdx].content,
      );
      if (selectedName == '默认工具描述') selectedName = '默认';
      needsUpdate = true;
    }

    if (selectedName == null && presets.isNotEmpty) {
      selectedName = presets.first.name;
      final manual = config.manualToolDescriptionBlocks;
      if (!_blocksEqual(manual, ImageConfig.defaultToolDescriptionBlocks)) {
        final encoded = ImageConfig.encodeToolDescriptionBlocks(manual);
        presets = presets.map((p) {
          if (p.name == selectedName) {
            return DrawingPromptPreset(name: p.name, content: encoded);
          }
          return p;
        }).toList();
      }
      needsUpdate = true;
    }

    if (!needsUpdate) return null;
    return config.copyWith(
      systemPromptPresets: presets,
      selectedSystemPromptPresetName: selectedName,
    );
  }

  bool _blocksEqual(
    DrawImageToolDescriptionBlocks a,
    DrawImageToolDescriptionBlocks b,
  ) {
    return a.toolDescription == b.toolDescription &&
        a.promptDescription == b.promptDescription &&
        a.negativePromptDescription == b.negativePromptDescription &&
        a.widthDescription == b.widthDescription &&
        a.heightDescription == b.heightDescription;
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final config = ref.watch(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);

    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(title: '稳定链路提示词模板', showBackButton: true),
      body: Builder(
        builder: (context) => ListView(
          padding: moeUnderBarPadding(
            context,
            EdgeInsets.fromLTRB(
              MoeSpacing.md,
              MoeSpacing.md,
              MoeSpacing.md,
              MoeSpacing.xl,
            ),
          ),
          children: [
            _buildSlotSection(context, config, notifier),
            const SizedBox(height: MoeSpacing.lg),
            _buildPreviewSection(context, config),
          ],
        ),
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
    final selectedName = config.selectedSystemPromptPresetName;

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
          '管理稳定链路下 draw_image 工具使用的提示词模板',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: MoeSpacing.sm),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            for (var i = 0; i < config.systemPromptPresets.length; i++)
              _slotRow(context, config, notifier, i, selectedName),
            MoeSettingsRow(
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
    final preset = config.systemPromptPresets[index];
    final isSelected = preset.name == selectedName;

    return MoeSettingsRow(
      icon: isSelected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: config.buildPresetPreview(preset),
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: colors.muted),
        onPressed: () =>
            _showSlotActions(context, config, notifier, preset, index),
      ),
      onTap: () {
        notifier.updateConfig(
          config.copyWith(selectedSystemPromptPresetName: preset.name),
        );
      },
      showDivider: true,
    );
  }

  // ━━━━━ 只读预览（显示当前选中槽位的内容） ━━━━━

  Widget _buildPreviewSection(BuildContext context, ImageConfig config) {
    final colors = context.moeColors;
    final blocks = config.effectiveToolDescriptionBlocks;
    final previewText = _buildPreviewText(blocks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _previewExpanded = !_previewExpanded),
          child: MoeButtonSurface(
            padding: const EdgeInsets.symmetric(
              horizontal: MoeSpacing.md,
              vertical: MoeSpacing.sm,
            ),
            tintColor: Colors.transparent,
            borderRadius: _previewExpanded
                ? const BorderRadius.vertical(
                    top: Radius.circular(MoeSmoothRadii.sm),
                  )
                : BorderRadius.circular(MoeSmoothRadii.sm),
            child: Row(
              children: [
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

  String _buildPreviewText(DrawImageToolDescriptionBlocks blocks) {
    final buf = StringBuffer();
    buf.writeln('[ 功能说明 ]');
    buf.writeln(blocks.toolDescription);
    buf.writeln();
    buf.writeln('[ 正面提示词规范 ]');
    buf.writeln(blocks.promptDescription);
    buf.writeln();
    buf.writeln('[ 反面提示词规范 ]');
    buf.writeln(blocks.negativePromptDescription);
    buf.writeln();
    buf.writeln('[ 宽度规则 ]');
    buf.writeln(blocks.widthDescription);
    buf.writeln();
    buf.writeln('[ 高度规则 ]');
    buf.writeln(blocks.heightDescription);
    return buf.toString().trimRight();
  }

  // ━━━━━ 弹窗 / 操作 ━━━━━

  void _openEditor(BuildContext context, String presetName) {
    Navigator.of(context).push(
      ParallaxSlidePageRoute(page: _PresetEditorPage(presetName: presetName)),
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
    if (config.systemPromptPresets.any((p) => p.name == name)) {
      MoeToast.warning(this.context, '已存在同名预设');
      return;
    }
    // 复制当前选中预设的内容
    final selectedBlocks = config.effectiveToolDescriptionBlocks;
    final preset = DrawingPromptPreset(
      name: name,
      content: ImageConfig.encodeToolDescriptionBlocks(selectedBlocks),
    );
    await notifier.updateConfig(
      config.copyWith(
        systemPromptPresets: [...config.systemPromptPresets, preset],
        selectedSystemPromptPresetName: name,
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
      description: config.buildPresetPreview(preset, max: 90),
      actions: [
        // 所有槽位都能编辑
        MoeSheetAction(
          label: '编辑',
          onTap: () => _openEditor(context, preset.name),
        ),
        // 非默认才能重命名
        if (!isFirst)
          MoeSheetAction(
            label: '重命名',
            onTap: () => _renameSlot(context, config, notifier, preset),
          ),
        // 非默认才能删除
        if (!isFirst)
          MoeSheetAction(
            label: '删除',
            isDestructive: true,
            onTap: () => _deleteSlot(config, notifier, preset),
          ),
      ],
    );
  }

  Future<void> _renameSlot(
    BuildContext context,
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    var currentName = preset.name;
    await showMoeAutoSaveTextEditor(
      context: context,
      title: '重命名预设',
      initialValue: currentName,
      onSave: (text) async {
        final name = text.trim();
        if (name.isEmpty) throw const FormatException('预设名称不能为空');
        if (name == currentName) return;
        final current = ref.read(imagePluginConfigProvider);
        final original = current.systemPromptPresets
            .where((p) => p.name == currentName)
            .firstOrNull;
        if (original == null) throw const FormatException('预设已不存在');
        if (current.systemPromptPresets.any((p) => p.name == name)) {
          throw const FormatException('已存在同名预设');
        }
        await notifier.updateConfig(
          current.copyWith(
            systemPromptPresets: current.systemPromptPresets
                .map(
                  (p) => p.name == currentName
                      ? DrawingPromptPreset(name: name, content: p.content)
                      : p,
                )
                .toList(),
            selectedSystemPromptPresetName:
                current.selectedSystemPromptPresetName == currentName
                ? name
                : current.selectedSystemPromptPresetName,
          ),
        );
        currentName = name;
      },
    );
  }

  Future<void> _deleteSlot(
    ImageConfig config,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    final updated = config.systemPromptPresets
        .where((p) => p.name != preset.name)
        .toList();
    final wasSelected = config.selectedSystemPromptPresetName == preset.name;
    await notifier.updateConfig(
      config.copyWith(
        systemPromptPresets: updated,
        selectedSystemPromptPresetName: wasSelected
            ? updated.first.name
            : config.selectedSystemPromptPresetName,
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
//  二级页面：编辑某个预设的详细内容
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _PresetEditorPage extends ConsumerStatefulWidget {
  final String presetName;
  const _PresetEditorPage({required this.presetName});

  @override
  ConsumerState<_PresetEditorPage> createState() => _PresetEditorPageState();
}

class _PresetEditorPageState extends ConsumerState<_PresetEditorPage>
    with MoeAutoSaveState<_PresetEditorPage> {
  late final TextEditingController _toolDescCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _negativeCtrl;
  late final TextEditingController _widthCtrl;
  late final TextEditingController _heightCtrl;

  List<TextEditingController> get _allControllers => [
    _toolDescCtrl,
    _promptCtrl,
    _negativeCtrl,
    _widthCtrl,
    _heightCtrl,
  ];

  @override
  void initState() {
    super.initState();
    final config = ref.read(imagePluginConfigProvider);
    final blocks = _loadBlocks(config);
    _toolDescCtrl = TextEditingController(text: blocks.toolDescription);
    _promptCtrl = TextEditingController(text: blocks.promptDescription);
    _negativeCtrl = TextEditingController(
      text: blocks.negativePromptDescription,
    );
    _widthCtrl = TextEditingController(text: blocks.widthDescription);
    _heightCtrl = TextEditingController(text: blocks.heightDescription);
    for (final c in _allControllers) {
      c.addListener(_onChanged);
    }
    autoSave.configure(
      save: _save,
      snapshot: () =>
          moeAutoSaveSignature([for (final c in _allControllers) c.text]),
      fields: _allControllers,
    );
  }

  @override
  void dispose() {
    for (final c in _allControllers) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  DrawImageToolDescriptionBlocks _loadBlocks(ImageConfig config) {
    final preset = config.systemPromptPresets
        .where((p) => p.name == widget.presetName)
        .firstOrNull;
    if (preset != null) {
      return ImageConfig.decodeToolDescriptionBlocks(preset.content) ??
          ImageConfig.defaultToolDescriptionBlocks;
    }
    return ImageConfig.defaultToolDescriptionBlocks;
  }

  DrawImageToolDescriptionBlocks _editingBlocks() {
    return DrawImageToolDescriptionBlocks(
      toolDescription: _toolDescCtrl.text.trim(),
      promptDescription: _promptCtrl.text.trim(),
      negativePromptDescription: _negativeCtrl.text.trim(),
      widthDescription: _widthCtrl.text.trim(),
      heightDescription: _heightCtrl.text.trim(),
    );
  }

  void _onChanged() => autoSave.changed();

  Future<void> _save() async {
    final config = ref.read(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);
    final encoded = ImageConfig.encodeToolDescriptionBlocks(_editingBlocks());
    final updatedPresets = config.systemPromptPresets.map((p) {
      if (p.name == widget.presetName) {
        return DrawingPromptPreset(name: p.name, content: encoded);
      }
      return p;
    }).toList();
    await notifier.updateConfig(
      config.copyWith(systemPromptPresets: updatedPresets),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return autoSavePage(
      MoePageScaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: colors.surface,
        appBar: MoeAppBar(
          title: '编辑「${widget.presetName}」',
          showBackButton: true,
        ),
        body: Builder(
          builder: (context) => ListView(
            padding: moeUnderBarPadding(
              context,
              EdgeInsets.fromLTRB(
                MoeSpacing.md,
                MoeSpacing.md,
                MoeSpacing.md,
                MoeSpacing.xl,
              ),
            ),
            children: [
              _fieldCard(
                context,
                title: '功能说明',
                hint: '告诉 AI 什么时候应该画图、怎么理解图片标签',
                controller: _toolDescCtrl,
              ),
              const SizedBox(height: MoeSpacing.sm),
              _groupLabel(context, '提示词规范'),
              const SizedBox(height: MoeSpacing.xs),
              _fieldCard(
                context,
                title: '正面提示词',
                hint: '教 AI 如何书写画面描述（标签顺序、权重语法、多人规则等）',
                controller: _promptCtrl,
              ),
              const SizedBox(height: MoeSpacing.sm),
              _fieldCard(
                context,
                title: '反面提示词',
                hint: '教 AI 如何书写排除内容（不想出现在画面中的元素）',
                controller: _negativeCtrl,
              ),
              const SizedBox(height: MoeSpacing.sm),
              _groupLabel(context, '尺寸规则'),
              const SizedBox(height: MoeSpacing.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _fieldCard(
                      context,
                      title: '宽度',
                      hint: '如：竖图 832、横图 1216',
                      controller: _widthCtrl,
                    ),
                  ),
                  const SizedBox(width: MoeSpacing.sm),
                  Expanded(
                    child: _fieldCard(
                      context,
                      title: '高度',
                      hint: '如：竖图 1216、横图 832',
                      controller: _heightCtrl,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 通用小组件（与主页面共用样式） ──

  Widget _groupLabel(BuildContext context, String text) {
    final colors = context.moeColors;
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: MoeSpacing.xs),
        Text(
          text,
          style: TextStyle(
            color: colors.text,
            fontSize: 14,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
      ],
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
