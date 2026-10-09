/// CharacterPluginsSection - 角色编辑页：插件
///
/// 「已开启插件」是一个统一行高的列表（顺序：音色、生图、记忆、酒馆、表情包、
/// 主动关怀、时间感知），每行只显示当前绑定的预设/入口，不放开关；开启与否只在
/// 末尾「管理开启的插件」容器里逐项管理，开启后对应行出现在上方列表。
/// 酒馆没有按角色开关位，始终在列表中显示绑定预设（未绑定时跟随默认，未设默认即空预设），
/// 也不出现在管理列表里。
library;

import '../../../../features/conversation_state/domain/mvu_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';
import '../../plugins/widgets/drawing_preset_picker_sheet.dart';
import '../../plugins/widgets/voice_preset_list.dart';
import 'preset_recipe_section.dart';

class CharacterPluginsSection extends ConsumerStatefulWidget {
  final Set<String> selectedPluginIds;
  final String? boundVoiceId;
  final List<VoicePreset> voicePresets;

  /// 用于绘图预设回显/选择的 personaPrompt（仅绘图相关字段有效）
  final String drawingPersonaPrompt;
  final String? selectedRecipeId;

  /// 是否可编辑角色记忆文档（仅编辑已有会话时可进入）
  final bool memoryDocAvailable;
  final VoidCallback? onOpenMemoryDoc;

  final ValueChanged<Set<String>> onPluginIdsChanged;
  final ValueChanged<String?> onVoiceChanged;
  final ValueChanged<String?> onDrawingPresetChanged;
  final ValueChanged<String?> onRecipeChanged;

  const CharacterPluginsSection({
    super.key,
    required this.selectedPluginIds,
    required this.boundVoiceId,
    required this.voicePresets,
    required this.drawingPersonaPrompt,
    required this.selectedRecipeId,
    required this.memoryDocAvailable,
    required this.onOpenMemoryDoc,
    required this.onPluginIdsChanged,
    required this.onVoiceChanged,
    required this.onDrawingPresetChanged,
    required this.onRecipeChanged,
  });

  @override
  ConsumerState<CharacterPluginsSection> createState() =>
      _CharacterPluginsSectionState();
}

class _CharacterPluginsSectionState
    extends ConsumerState<CharacterPluginsSection> {
  bool _allExpanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    final plugins = <_PluginSpec>[
      _PluginSpec(
        id: 'tts',
        label: '音色',
        binding: _BindingSpec(
          value: _voiceDisplayName(),
          onTap: () => _showVoicePicker(context),
        ),
      ),
      _PluginSpec(
        id: 'image',
        label: '生图',
        binding: _BindingSpec(
          value: _drawingPresetDisplayName(),
          onTap: () => showDrawingPresetPicker(
            context: context,
            ref: ref,
            personaPrompt: widget.drawingPersonaPrompt,
            onSelected: widget.onDrawingPresetChanged,
          ),
        ),
      ),
      _PluginSpec(
        id: 'memory',
        label: '记忆',
        binding: _BindingSpec(
          value: widget.memoryDocAvailable ? '角色记忆文档' : '开始聊天后可编辑',
          onTap: widget.memoryDocAvailable ? widget.onOpenMemoryDoc : null,
        ),
      ),
      _PluginSpec(
        id: 'tavern',
        label: '酒馆',
        alwaysOn: true,
        binding: _BindingSpec(
          value: _tavernPresetDisplayName(),
          onTap: () => showTavernPresetPicker(
            context: context,
            selectedRecipeId: widget.selectedRecipeId,
            onChanged: widget.onRecipeChanged,
          ),
        ),
      ),
      const _PluginSpec(id: mvuPluginId, label: 'MVU 变量'),
      const _PluginSpec(id: 'sticker', label: '表情包'),
      const _PluginSpec(id: 'trigger', label: '主动关怀'),
      const _PluginSpec(id: 'time_awareness', label: '时间感知'),
      const _PluginSpec(id: 'web_search', label: '联网搜索'),
    ];

    final active = plugins.where(_isActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
          child: Text(
            '已开启插件',
            style: TextStyle(
              fontSize: 13,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.primary,
            ),
          ),
        ),
        _enabledList(colors, active),
        const SizedBox(height: 12),
        _allPluginsCard(colors, [
          for (final p in plugins)
            if (!p.alwaysOn) p,
        ]),
      ],
    );
  }

  bool _isActive(_PluginSpec plugin) =>
      plugin.alwaysOn || widget.selectedPluginIds.contains(plugin.id);

  // ==================== 已开启插件列表 ====================

  Widget _enabledList(MoeColors colors, List<_PluginSpec> active) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        for (var i = 0; i < active.length; i++)
          _enabledRow(colors, active[i], showDivider: i < active.length - 1),
      ],
    );
  }

  Widget _enabledRow(
    MoeColors colors,
    _PluginSpec plugin, {
    required bool showDivider,
  }) {
    final binding = plugin.binding;
    return MoeSettingsRow(
      key: ValueKey('enabled-plugin-${plugin.id}'),
      label: plugin.label,
      showDivider: showDivider,
      trailingType: binding == null
          ? MoeSettingsRowTrailing.none
          : MoeSettingsRowTrailing.custom,
      // 绑定名单行省略，保证每行等高
      expandTrailing: binding != null,
      trailing: binding == null ? null : _bindingTrailing(colors, binding),
      onTap: binding?.onTap,
    );
  }

  Widget _bindingTrailing(MoeColors colors, _BindingSpec binding) {
    return Row(
      children: [
        Expanded(
          child: Text(
            binding.value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: colors.muted),
          ),
        ),
        if (binding.onTap != null) ...[
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 20, color: colors.muted),
        ],
      ],
    );
  }

  // ==================== 管理开启的插件容器 ====================

  Widget _allPluginsCard(MoeColors colors, List<_PluginSpec> plugins) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          label: '管理开启的插件',
          showDivider: _allExpanded,
          trailingType: MoeSettingsRowTrailing.custom,
          trailing: AnimatedRotation(
            turns: _allExpanded ? 0.5 : 0,
            duration: kAnimFast,
            child: Icon(Icons.expand_more, size: 20, color: colors.muted),
          ),
          onTap: () => setState(() => _allExpanded = !_allExpanded),
        ),
        AnimatedSize(
          duration: kAnimFast,
          curve: Curves.easeOut,
          child: _allExpanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < plugins.length; i++)
                      _switchRow(
                        colors,
                        plugins[i],
                        showDivider: i < plugins.length - 1,
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _switchRow(
    MoeColors colors,
    _PluginSpec plugin, {
    required bool showDivider,
  }) {
    final value = widget.selectedPluginIds.contains(plugin.id);
    return MoeSettingsRow(
      key: ValueKey('all-plugins-${plugin.id}'),
      label: plugin.label,
      showDivider: showDivider,
      trailingType: MoeSettingsRowTrailing.custom,
      // 开关不参与行高计算，行高与上方已开启插件列表一致
      trailing: SizedBox(
        width: 52,
        height: 0,
        child: OverflowBox(
          maxHeight: 40,
          child: IgnorePointer(
            child: Switch(
              value: value,
              onChanged: (_) {},
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeTrackColor: colors.focus,
              thumbColor: WidgetStateProperty.all(Colors.white),
            ),
          ),
        ),
      ),
      onTap: () => _togglePlugin(plugin.id, !value),
    );
  }

  void _togglePlugin(String pluginId, bool value) {
    final next = Set<String>.from(widget.selectedPluginIds);
    if (value) {
      next.add(pluginId);
    } else {
      next.remove(pluginId);
    }
    widget.onPluginIdsChanged(next);
  }

  // ==================== 酒馆 ====================

  String _tavernPresetDisplayName() {
    final presetsAsync = ref.watch(presetRecipeListProvider);
    if (presetsAsync.hasError) return '预设列表读取失败，请到管理页检查';
    if (presetsAsync.isLoading) return '正在加载…';
    final presets = presetsAsync.valueOrNull ?? const <PresetRecipeSummary>[];
    if (widget.selectedRecipeId != null) {
      return tavernPresetDisplayName(presets, widget.selectedRecipeId);
    }
    // 未设默认预设时即空预设：不套用任何酒馆提示词
    final defaultId = ref
        .watch(tavernPluginSettingsProvider)
        .valueOrNull
        ?.defaultPresetId;
    final defaultName = presets
        .where((p) => p.id == defaultId)
        .firstOrNull
        ?.name;
    return '跟随默认 · ${defaultName ?? '空预设'}';
  }

  // ==================== 音色 ====================

  String _voiceDisplayName() {
    final id = widget.boundVoiceId;
    if (id == null || id.isEmpty) return '跟随默认音色配置包';

    for (final preset in widget.voicePresets) {
      if (preset.id == id) return preset.name;
    }

    return '绑定的预设已丢失，请重新选择';
  }

  Future<void> _showVoicePicker(BuildContext context) async {
    const followGlobalToken = '__follow_global__';

    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择音色配置包',
      showCloseButton: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final settings = ref.watch(appSettingsProvider).valueOrNull;
          final config = ref.watch(ttsPluginConfigProvider);
          return VoicePresetList(
            presets: widget.voicePresets,
            selectedId: widget.boundVoiceId,
            defaultId: config.defaultVoicePresetId,
            allowDefault: true,
            providerNames: {
              for (final p in settings?.providers ?? [])
                p.id: p.displayName ?? p.id,
            },
            onSelect: (preset) =>
                Navigator.of(context).pop(preset?.id ?? followGlobalToken),
          );
        },
      ),
    );

    if (selected == null || !context.mounted) return;
    if (selected == followGlobalToken) {
      widget.onVoiceChanged(null);
    } else {
      widget.onVoiceChanged(selected);
    }
  }

  // ==================== 生图 ====================

  bool get _drawingFollowsDefault {
    final parts = PersonaPromptCodec.parse(widget.drawingPersonaPrompt);
    return (parts.drawingPresetId?.isEmpty ?? true) &&
        (parts.drawingToolPresetName?.isEmpty ?? true) &&
        (parts.drawingArtistPresetName?.isEmpty ?? true);
  }

  String _drawingPresetDisplayName() {
    final selected = ref.watch(
      roleDrawingPresetProvider(widget.drawingPersonaPrompt),
    );
    final catalog = ref.watch(drawingPresetCatalogProvider);
    if (!catalog.hasValue) return '配置包读取中…';
    return selected.when(
      loading: () => '正在加载…',
      error: (_, stack) => '配置不可用，请重新选择',
      data: (preset) =>
          _drawingFollowsDefault ? '跟随默认 · ${preset.name}' : preset.name,
    );
  }
}

class _PluginSpec {
  final String id;
  final String label;
  final _BindingSpec? binding;

  /// 没有按角色开关位，始终显示在已开启列表里，不进入管理列表
  final bool alwaysOn;

  const _PluginSpec({
    required this.id,
    required this.label,
    this.binding,
    this.alwaysOn = false,
  });
}

class _BindingSpec {
  final String value;
  final VoidCallback? onTap;

  const _BindingSpec({required this.value, this.onTap});
}
