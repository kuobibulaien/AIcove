/// CharacterPluginsSection - 角色编辑页：插件
///
/// 已开启的插件各占一个容器（顺序：音色、生图、记忆、酒馆、表情包、主动关怀、
/// 时间感知），容器内是开关和当前绑定的预设/入口；末尾「全部插件」容器展开后
/// 逐项开关，开启后对应容器动态出现在上方。
/// 酒馆没有按角色开关位，始终单独成一个容器显示绑定预设（未绑定时跟随默认酒馆预设）。
library;

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
          label: '音色配置包',
          value: _voiceDisplayName(),
          onTap: () => _showVoicePicker(context),
        ),
      ),
      _PluginSpec(
        id: 'image',
        label: '生图',
        binding: _BindingSpec(
          label: '绘图配置包',
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
          label: '角色记忆文档',
          value: widget.memoryDocAvailable ? '' : '开始聊天后可编辑',
          onTap: widget.memoryDocAvailable ? widget.onOpenMemoryDoc : null,
        ),
      ),
      const _PluginSpec(id: 'sticker', label: '表情包'),
      const _PluginSpec(id: 'trigger', label: '主动关怀'),
      const _PluginSpec(id: 'time_awareness', label: '时间感知'),
    ];

    final cards = <Widget>[
      for (final plugin in plugins.take(3))
        if (_isActive(plugin.id)) _enabledCard(colors, plugin),
      _tavernCard(context),
      for (final plugin in plugins.skip(3))
        if (_isActive(plugin.id)) _enabledCard(colors, plugin),
      _allPluginsCard(colors, plugins),
    ];

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
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          cards[i],
        ],
      ],
    );
  }

  bool _isActive(String pluginId) =>
      widget.selectedPluginIds.contains(pluginId) &&
      _isPluginGloballyEnabled(pluginId);

  // ==================== 已开启插件容器 ====================

  Widget _enabledCard(MoeColors colors, _PluginSpec plugin) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          label: plugin.label,
          showDivider: false,
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: true,
          onSwitchChanged: (value) => _togglePlugin(plugin.id, value),
        ),
        if (plugin.binding != null) _bindingLine(colors, plugin.binding!),
      ],
    );
  }

  // ==================== 全部插件容器 ====================

  Widget _allPluginsCard(MoeColors colors, List<_PluginSpec> plugins) {
    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          label: '全部插件',
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

  Widget _switchRow(_PluginSpec plugin, {required bool showDivider}) {
    final globallyEnabled = _isPluginGloballyEnabled(plugin.id);
    return MoeSettingsRow(
      key: ValueKey('all-plugins-${plugin.id}'),
      label: plugin.label,
      subtitle: globallyEnabled ? null : '全局未开启，需先在聊天插件中启用',
      enabled: globallyEnabled,
      showDivider: showDivider,
      trailingType: MoeSettingsRowTrailing.switchControl,
      switchValue: widget.selectedPluginIds.contains(plugin.id),
      onSwitchChanged: globallyEnabled
          ? (value) => _togglePlugin(plugin.id, value)
          : null,
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

  /// 普通聊天插件恒为全局开启，仅主动关怀仍受全局服务开关约束。
  bool _isPluginGloballyEnabled(String pluginId) {
    if (pluginId != 'trigger') return true;
    return ref.read(appSettingsProvider).value?.autoReplySettings.enabled ??
        false;
  }

  /// 绑定行：对齐主行文字，一行展示当前绑定，点击更换。
  Widget _bindingLine(MoeColors colors, _BindingSpec spec) {
    final enabled = spec.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: spec.onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        child: Row(
          children: [
            Text(
              spec.label,
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                spec.value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: enabled ? colors.text : colors.muted,
                ),
              ),
            ),
            if (enabled) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: colors.muted),
            ],
          ],
        ),
      ),
    );
  }

  // ==================== 酒馆容器（无开关，直接显示绑定预设） ====================

  Widget _tavernCard(BuildContext context) {
    final presetsAsync = ref.watch(presetRecipeListProvider);
    final presets = presetsAsync.valueOrNull ?? const <PresetRecipeSummary>[];

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        MoeSettingsRow(
          label: '酒馆',
          subtitle: presetsAsync.hasError ? '预设列表读取失败，请到管理页检查' : null,
          showDivider: false,
          trailingType: MoeSettingsRowTrailing.text,
          detailText: presetsAsync.isLoading
              ? '正在加载…'
              : tavernPresetDisplayName(presets, widget.selectedRecipeId),
          onTap: () => showTavernPresetPicker(
            context: context,
            selectedRecipeId: widget.selectedRecipeId,
            onChanged: widget.onRecipeChanged,
          ),
        ),
      ],
    );
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

  const _PluginSpec({required this.id, required this.label, this.binding});
}

class _BindingSpec {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _BindingSpec({required this.label, required this.value, this.onTap});
}
