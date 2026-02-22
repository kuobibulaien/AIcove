import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/plugins/image/image_config.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class DrawingPromptPage extends ConsumerStatefulWidget {
  const DrawingPromptPage({super.key});

  @override
  ConsumerState<DrawingPromptPage> createState() => _DrawingPromptPageState();
}

class _DrawingPromptPageState extends ConsumerState<DrawingPromptPage> {
  late TextEditingController _promptController;
  bool _promptDirty = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(imagePluginConfigProvider);
    _promptController = TextEditingController(text: config.drawingSystemPrompt);
    _promptController.addListener(_onPromptChanged);
  }

  void _onPromptChanged() {
    final config = ref.read(imagePluginConfigProvider);
    final dirty = _promptController.text != config.drawingSystemPrompt;
    if (dirty != _promptDirty) setState(() => _promptDirty = dirty);
  }

  @override
  void dispose() {
    _promptController.removeListener(_onPromptChanged);
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final config = ref.watch(imagePluginConfigProvider);
    final notifier = ref.read(imagePluginConfigProvider.notifier);

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '绘图提示词',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        children: [
          // ── 画师串预设 ──
          _buildPresetSection(
            context: context,
            config: config,
            notifier: notifier,
          ),
          const SizedBox(height: 24),

          // ── 绘图提示词编辑 ──
          _buildPromptEditor(
            context: context,
            config: config,
            notifier: notifier,
          ),
          const SizedBox(height: 24),

          // ── 最终提示词预览 ──
          _buildPreview(context: context, config: config),
        ],
      ),
    );
  }

  // ─────────────────── 画师串预设区域 ───────────────────

  Widget _buildPresetSection({
    required BuildContext context,
    required ImageConfig config,
    required ImagePluginConfigNotifier notifier,
  }) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '画师串预设',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '选择一个画师串预设，AI 生图时会自动在 prompt 前面加上对应的画师串。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            // "不使用" 选项
            MoeSettingsRow(
              icon: config.selectedArtistPresetName == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '不使用预设',
              onTap: () => notifier.selectArtistPreset(null),
            ),
            // 各个预设
            for (var i = 0; i < config.artistPresets.length; i++)
              _buildPresetRow(
                context: context,
                preset: config.artistPresets[i],
                selected: config.selectedArtistPresetName ==
                    config.artistPresets[i].name,
                notifier: notifier,
                isLast: i == config.artistPresets.length - 1,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: MoeSecondaryButton(
            label: '添加画师串预设',
            icon: Icons.add,
            onPressed: () => _showAddPresetSheet(context, notifier),
          ),
        ),
      ],
    );
  }

  Widget _buildPresetRow({
    required BuildContext context,
    required ArtistPreset preset,
    required bool selected,
    required ImagePluginConfigNotifier notifier,
    required bool isLast,
  }) {
    return MoeSettingsRow(
      icon: selected
          ? Icons.radio_button_checked
          : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: preset.content.length > 60
          ? '${preset.content.substring(0, 60)}...'
          : preset.content,
      labelMaxLines: 1,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: context.moeColors.muted),
        onPressed: () => _showPresetActions(context, notifier, preset),
      ),
      onTap: () => notifier.selectArtistPreset(preset.name),
      showDivider: !isLast,
    );
  }

  // ─────────────────── 提示词编辑区域 ───────────────────

  Widget _buildPromptEditor({
    required BuildContext context,
    required ImageConfig config,
    required ImagePluginConfigNotifier notifier,
  }) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '绘图提示词',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '此提示词会作为系统指令发送给 AI，告诉它如何书写绘图 prompt。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _promptController,
          maxLines: 10,
          style: TextStyle(fontSize: 13, color: colors.text),
          decoration: InputDecoration(
            hintText: '输入自定义绘图提示词...',
            hintStyle: TextStyle(color: colors.muted),
            border: const OutlineInputBorder(),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: colors.borderLight),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              onTap: () {
                _promptController.text =
                    ImageConfig.defaultDrawingSystemPrompt;
              },
              child: Text(
                '恢复默认',
                style: TextStyle(fontSize: 13, color: colors.primary),
              ),
            ),
            const SizedBox(width: 16),
            if (_promptDirty)
              GestureDetector(
                onTap: () async {
                  await notifier
                      .setDrawingSystemPrompt(_promptController.text);
                  setState(() => _promptDirty = false);
                  if (mounted) MoeToast.success(context, '已保存');
                },
                child: Text(
                  '保存',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.primary,
                    fontWeight: MoeFontWeights.emphasis,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ─────────────────── 最终提示词预览 ───────────────────

  Widget _buildPreview({
    required BuildContext context,
    required ImageConfig config,
  }) {
    final colors = context.moeColors;
    // 用当前编辑框文本和选中预设来计算预览
    final basePrompt = _promptController.text.trim().isNotEmpty
        ? _promptController.text
        : ImageConfig.defaultDrawingSystemPrompt;
    final preset = config.selectedArtistPreset;
    final preview = preset == null
        ? basePrompt
        : '$basePrompt\n\n## 用户默认画师串预设\n'
            '用户设置的默认画师串预设是：\n${preset.content}\n'
            '如果没有其他需要，请在生成图片的 prompt 前面加上这段画师串。';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '最终提示词预览',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '以下是实际发送给 AI 的完整系统提示词（只读）。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.componentBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.borderLight),
          ),
          child: SelectableText(
            preview,
            style: TextStyle(fontSize: 12, color: colors.muted, height: 1.5),
          ),
        ),
      ],
    );
  }

  // ─────────────────── 弹窗：添加预设 ───────────────────

  Future<void> _showAddPresetSheet(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
  ) async {
    final nameController = TextEditingController();
    final contentController = TextEditingController();

    await showMoeBottomSheet(
      context: context,
      title: '添加画师串预设',
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '预设名称',
                hintText: '例如：防冻液',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '画师串内容',
                hintText:
                    '例如：[[omochi monaka]] ,{{kele mimi}} ,[ruriri], ...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            MoePrimaryButton(
              label: '保存',
              onPressed: () async {
                final name = nameController.text.trim();
                final content = contentController.text.trim();
                if (name.isEmpty || content.isEmpty) {
                  MoeToast.warning(ctx, '名称和内容不能为空');
                  return;
                }
                final config = ref.read(imagePluginConfigProvider);
                if (config.artistPresets.any((p) => p.name == name)) {
                  MoeToast.warning(ctx, '已存在同名预设');
                  return;
                }
                await notifier.addArtistPreset(
                  ArtistPreset(name: name, content: content),
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    contentController.dispose();
  }

  // ─────────────────── 弹窗：预设操作 ───────────────────

  Future<void> _showPresetActions(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
  ) async {
    await showMoeActionSheet(
      context: context,
      title: preset.name,
      description: preset.content.length > 100
          ? '${preset.content.substring(0, 100)}...'
          : preset.content,
      actions: [
        MoeSheetAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          onTap: () => _showEditPresetSheet(context, notifier, preset),
        ),
        MoeSheetAction(
          icon: Icons.delete_outline,
          label: '删除',
          isDestructive: true,
          onTap: () async {
            await notifier.removeArtistPreset(preset.name);
            if (context.mounted) MoeToast.brief(context, '已删除');
          },
        ),
      ],
    );
  }

  Future<void> _showEditPresetSheet(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
  ) async {
    final nameController = TextEditingController(text: preset.name);
    final contentController = TextEditingController(text: preset.content);

    await showMoeBottomSheet(
      context: context,
      title: '编辑画师串预设',
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '预设名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '画师串内容',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            MoePrimaryButton(
              label: '保存修改',
              onPressed: () async {
                final name = nameController.text.trim();
                final content = contentController.text.trim();
                if (name.isEmpty || content.isEmpty) {
                  MoeToast.warning(ctx, '名称和内容不能为空');
                  return;
                }
                await notifier.updateArtistPreset(
                  preset.name,
                  ArtistPreset(name: name, content: content),
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    contentController.dispose();
  }
}
