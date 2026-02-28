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

    if (!_promptDirty && _promptController.text != config.drawingSystemPrompt) {
      _promptController.text = config.drawingSystemPrompt;
    }

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: const MoeAppBar(
        title: '绘图提示词',
        showBackButton: true,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        children: [
          _buildSystemPromptPresetSection(
            context: context,
            config: config,
            notifier: notifier,
          ),
          const SizedBox(height: 24),
          _buildPromptEditor(
            context: context,
            config: config,
            notifier: notifier,
          ),
          const SizedBox(height: 24),
          _buildArtistPresetSection(
            context: context,
            config: config,
            notifier: notifier,
          ),
          const SizedBox(height: 24),
          _buildPreview(context: context, config: config),
        ],
      ),
    );
  }

  Widget _buildSystemPromptPresetSection({
    required BuildContext context,
    required ImageConfig config,
    required ImagePluginConfigNotifier notifier,
  }) {
    final colors = context.moeColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '系统提示词预设',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '选择一套提示词规范，适配不同生图模型。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        MoeSettingsGroup(
          margin: EdgeInsets.zero,
          children: [
            MoeSettingsRow(
              icon: config.selectedSystemPromptPresetName == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '手动自定义',
              subtitle: '使用下方编辑框中的内容',
              labelMaxLines: 1,
              onTap: () => _selectSystemPromptPreset(
                notifier: notifier,
                config: config,
                presetName: null,
              ),
            ),
            for (var i = 0; i < config.systemPromptPresets.length; i++)
              _buildSystemPromptPresetRow(
                context: context,
                preset: config.systemPromptPresets[i],
                selected: config.selectedSystemPromptPresetName ==
                    config.systemPromptPresets[i].name,
                notifier: notifier,
                config: config,
                isLast: i == config.systemPromptPresets.length - 1,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: MoeSecondaryButton(
            label: '添加系统提示词预设',
            icon: Icons.add,
            onPressed: () =>
                _navigateToAddSystemPromptPresetPage(context, notifier),
          ),
        ),
      ],
    );
  }

  Widget _buildSystemPromptPresetRow({
    required BuildContext context,
    required DrawingPromptPreset preset,
    required bool selected,
    required ImagePluginConfigNotifier notifier,
    required ImageConfig config,
    required bool isLast,
  }) {
    return MoeSettingsRow(
      icon:
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: _shortenText(preset.content, 60),
      labelMaxLines: 1,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: context.moeColors.muted),
        onPressed: () =>
            _showSystemPromptPresetActions(context, notifier, preset),
      ),
      onTap: () => _selectSystemPromptPreset(
        notifier: notifier,
        config: config,
        presetName: preset.name,
      ),
      showDivider: !isLast,
    );
  }

  Widget _buildPromptEditor({
    required BuildContext context,
    required ImageConfig config,
    required ImagePluginConfigNotifier notifier,
  }) {
    final colors = context.moeColors;
    final selectedPreset = config.selectedSystemPromptPreset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '手动自定义提示词',
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: MoeFontWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '仅在「系统提示词预设」选择“手动自定义”时生效。',
          style: TextStyle(color: colors.muted, fontSize: 13),
        ),
        if (selectedPreset != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.componentBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.borderLight),
            ),
            child: Text(
              '当前正在使用预设：${selectedPreset.name}。\n你在这里的修改会保留，切回「手动自定义」后生效。',
              style: TextStyle(color: colors.muted, fontSize: 12, height: 1.5),
            ),
          ),
        ],
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
                _promptController.text = ImageConfig.defaultDrawingSystemPrompt;
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
                  await notifier.setDrawingSystemPrompt(_promptController.text);
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

  Widget _buildArtistPresetSection({
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
            MoeSettingsRow(
              icon: config.selectedArtistPresetName == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '不使用预设',
              onTap: () => notifier.selectArtistPreset(null),
            ),
            for (var i = 0; i < config.artistPresets.length; i++)
              _buildArtistPresetRow(
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
            onPressed: () => _navigateToAddArtistPresetPage(context, notifier),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistPresetRow({
    required BuildContext context,
    required ArtistPreset preset,
    required bool selected,
    required ImagePluginConfigNotifier notifier,
    required bool isLast,
  }) {
    return MoeSettingsRow(
      icon:
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      label: preset.name,
      subtitle: _shortenText(preset.content, 60),
      labelMaxLines: 1,
      trailingType: MoeSettingsRowTrailing.custom,
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, color: context.moeColors.muted),
        onPressed: () => _showArtistPresetActions(context, notifier, preset),
      ),
      onTap: () => notifier.selectArtistPreset(preset.name),
      showDivider: !isLast,
    );
  }

  Widget _buildPreview({
    required BuildContext context,
    required ImageConfig config,
  }) {
    final colors = context.moeColors;
    final selectedSystemPreset = config.selectedSystemPromptPreset;
    final basePrompt = selectedSystemPreset != null
        ? selectedSystemPreset.content
        : (_promptController.text.trim().isNotEmpty
            ? _promptController.text
            : ImageConfig.defaultDrawingSystemPrompt);
    final artistPreset = config.selectedArtistPreset;

    final preview = artistPreset == null
        ? '$basePrompt\n\n## 当前系统提示词来源\n${selectedSystemPreset?.name ?? '手动自定义'}'
        : '$basePrompt\n\n## 当前系统提示词来源\n${selectedSystemPreset?.name ?? '手动自定义'}\n\n## 用户默认画师串预设\n用户设置的默认画师串预设是：\n${artistPreset.content}\n如果没有其他需要，请在生成图片的 prompt 前面加上这段画师串。';

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

  Future<void> _selectSystemPromptPreset({
    required ImagePluginConfigNotifier notifier,
    required ImageConfig config,
    required String? presetName,
  }) async {
    await notifier.updateConfig(
      config.copyWith(
        selectedSystemPromptPresetName: presetName,
        clearSelectedSystemPromptPreset: presetName == null,
      ),
    );
  }

  Future<void> _navigateToAddSystemPromptPresetPage(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
  ) async {
    final draft = await _openPresetEditorPage(
      context: context,
      pageTitle: '添加系统提示词预设',
      nameLabel: '预设名称',
      nameHint: '例如：SDXL 通用',
      contentLabel: '系统提示词内容',
      contentHint: '输入这套模型专用的提示词规范...',
      saveLabel: '保存',
      validator: (name, _) {
        final currentConfig = ref.read(imagePluginConfigProvider);
        if (currentConfig.systemPromptPresets.any((p) => p.name == name)) {
          return '已存在同名预设';
        }
        return null;
      },
    );

    if (draft == null) return;

    final currentConfig = ref.read(imagePluginConfigProvider);
    final updated = [
      ...currentConfig.systemPromptPresets,
      DrawingPromptPreset(name: draft.name, content: draft.content),
    ];

    await notifier.updateConfig(
      currentConfig.copyWith(systemPromptPresets: updated),
    );

    if (!mounted) return;
    MoeToast.success(context, '已保存');
  }

  Future<_PresetDraft?> _openPresetEditorPage({
    required BuildContext context,
    required String pageTitle,
    required String nameLabel,
    required String nameHint,
    required String contentLabel,
    required String contentHint,
    required String saveLabel,
    String initialName = '',
    String initialContent = '',
    _PresetValidator? validator,
  }) {
    return Navigator.of(context).push<_PresetDraft>(
      MaterialPageRoute(
        builder: (_) => _PresetEditorPage(
          pageTitle: pageTitle,
          nameLabel: nameLabel,
          nameHint: nameHint,
          contentLabel: contentLabel,
          contentHint: contentHint,
          saveLabel: saveLabel,
          initialName: initialName,
          initialContent: initialContent,
          validator: validator,
        ),
      ),
    );
  }

  Future<void> _showSystemPromptPresetActions(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    await showMoeActionSheet(
      context: context,
      title: preset.name,
      description: _shortenText(preset.content, 100),
      actions: [
        MoeSheetAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          onTap: () =>
              _navigateToEditSystemPromptPresetPage(context, notifier, preset),
        ),
        MoeSheetAction(
          icon: Icons.delete_outline,
          label: '删除',
          isDestructive: true,
          onTap: () async {
            final currentConfig = ref.read(imagePluginConfigProvider);
            final updated = currentConfig.systemPromptPresets
                .where((p) => p.name != preset.name)
                .toList();
            await notifier.updateConfig(
              currentConfig.copyWith(
                systemPromptPresets: updated,
                clearSelectedSystemPromptPreset:
                    currentConfig.selectedSystemPromptPresetName == preset.name,
              ),
            );
            if (context.mounted) MoeToast.brief(context, '已删除');
          },
        ),
      ],
    );
  }

  Future<void> _navigateToEditSystemPromptPresetPage(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    DrawingPromptPreset preset,
  ) async {
    final draft = await _openPresetEditorPage(
      context: context,
      pageTitle: '编辑系统提示词预设',
      nameLabel: '预设名称',
      nameHint: '',
      contentLabel: '系统提示词内容',
      contentHint: '',
      saveLabel: '保存修改',
      initialName: preset.name,
      initialContent: preset.content,
      validator: (name, _) {
        final currentConfig = ref.read(imagePluginConfigProvider);
        if (currentConfig.systemPromptPresets
            .any((p) => p.name == name && p.name != preset.name)) {
          return '已存在同名预设';
        }
        return null;
      },
    );

    if (draft == null) return;

    final currentConfig = ref.read(imagePluginConfigProvider);
    final updated = currentConfig.systemPromptPresets
        .map(
          (p) => p.name == preset.name
              ? DrawingPromptPreset(name: draft.name, content: draft.content)
              : p,
        )
        .toList();
    final shouldUpdateSelection =
        currentConfig.selectedSystemPromptPresetName == preset.name;

    await notifier.updateConfig(
      currentConfig.copyWith(
        systemPromptPresets: updated,
        selectedSystemPromptPresetName: shouldUpdateSelection
            ? draft.name
            : currentConfig.selectedSystemPromptPresetName,
      ),
    );

    if (!mounted) return;
    MoeToast.success(context, '已保存');
  }

  Future<void> _navigateToAddArtistPresetPage(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
  ) async {
    final draft = await _openPresetEditorPage(
      context: context,
      pageTitle: '添加画师串预设',
      nameLabel: '预设名称',
      nameHint: '例如：防冻液',
      contentLabel: '画师串内容',
      contentHint: '例如：[[omochi monaka]] ,{{kele mimi}} ,[ruriri], ...',
      saveLabel: '保存',
      validator: (name, _) {
        final currentConfig = ref.read(imagePluginConfigProvider);
        if (currentConfig.artistPresets.any((p) => p.name == name)) {
          return '已存在同名预设';
        }
        return null;
      },
    );

    if (draft == null) return;

    await notifier.addArtistPreset(
      ArtistPreset(name: draft.name, content: draft.content),
    );

    if (!mounted) return;
    MoeToast.success(context, '已保存');
  }

  Future<void> _showArtistPresetActions(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
  ) async {
    await showMoeActionSheet(
      context: context,
      title: preset.name,
      description: _shortenText(preset.content, 100),
      actions: [
        MoeSheetAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          onTap: () =>
              _navigateToEditArtistPresetPage(context, notifier, preset),
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

  Future<void> _navigateToEditArtistPresetPage(
    BuildContext context,
    ImagePluginConfigNotifier notifier,
    ArtistPreset preset,
  ) async {
    final draft = await _openPresetEditorPage(
      context: context,
      pageTitle: '编辑画师串预设',
      nameLabel: '预设名称',
      nameHint: '',
      contentLabel: '画师串内容',
      contentHint: '',
      saveLabel: '保存修改',
      initialName: preset.name,
      initialContent: preset.content,
      validator: (name, _) {
        final currentConfig = ref.read(imagePluginConfigProvider);
        if (currentConfig.artistPresets
            .any((p) => p.name == name && p.name != preset.name)) {
          return '已存在同名预设';
        }
        return null;
      },
    );

    if (draft == null) return;

    await notifier.updateArtistPreset(
      preset.name,
      ArtistPreset(name: draft.name, content: draft.content),
    );

    if (!mounted) return;
    MoeToast.success(context, '已保存');
  }

  String _shortenText(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}...';
  }
}

typedef _PresetValidator = String? Function(String name, String content);

class _PresetDraft {
  const _PresetDraft({
    required this.name,
    required this.content,
  });

  final String name;
  final String content;
}

class _PresetEditorPage extends StatefulWidget {
  const _PresetEditorPage({
    required this.pageTitle,
    required this.nameLabel,
    required this.nameHint,
    required this.contentLabel,
    required this.contentHint,
    required this.saveLabel,
    required this.initialName,
    required this.initialContent,
    this.validator,
  });

  final String pageTitle;
  final String nameLabel;
  final String nameHint;
  final String contentLabel;
  final String contentHint;
  final String saveLabel;
  final String initialName;
  final String initialContent;
  final _PresetValidator? validator;

  @override
  State<_PresetEditorPage> createState() => _PresetEditorPageState();
}

class _PresetEditorPageState extends State<_PresetEditorPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _contentController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _contentController = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _handleSave() {
    final name = _nameController.text.trim();
    final content = _contentController.text.trim();

    if (name.isEmpty || content.isEmpty) {
      MoeToast.warning(context, '名称和内容不能为空');
      return;
    }

    final validation = widget.validator?.call(name, content);
    if (validation != null) {
      MoeToast.warning(context, validation);
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(_PresetDraft(name: name, content: content));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Scaffold(
      backgroundColor: colors.surface,
      appBar: MoeAppBar(
        title: widget.pageTitle,
        showBackButton: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: widget.nameLabel,
                          hintText:
                              widget.nameHint.isEmpty ? null : widget.nameHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _contentController,
                        minLines: 8,
                        maxLines: 14,
                        decoration: InputDecoration(
                          labelText: widget.contentLabel,
                          hintText: widget.contentHint.isEmpty
                              ? null
                              : widget.contentHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              MoePrimaryButton(
                label: widget.saveLabel,
                onPressed: _handleSave,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
