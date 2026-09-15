/// CharacterPluginsSection - 角色编辑页：插件列表
///
/// 每行一个插件，顺序：音色、生图、记忆、酒馆、表情包、主动关怀、时间感知。
/// 开关控制「本角色是否允许使用」；允许后才展开一行当前绑定的预设/入口。
/// 酒馆没有按角色开关位，单行直接显示绑定预设（未绑定时跟随插件默认预设）。
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

class CharacterPluginsSection extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.moeColors;

    final entries = <Widget>[
      _pluginEntry(
        ref,
        colors,
        pluginId: 'tts',
        icon: Icons.record_voice_over_outlined,
        label: '音色',
        binding: _BindingSpec(
          label: '音色配置包',
          value: _voiceDisplayName(),
          onTap: () => _showVoicePicker(context),
        ),
      ),
      _pluginEntry(
        ref,
        colors,
        pluginId: 'image',
        icon: Icons.draw_outlined,
        label: '生图',
        binding: _BindingSpec(
          label: '绘图配置包',
          value: _drawingPresetDisplayName(ref),
          onTap: () => showDrawingPresetPicker(
            context: context,
            ref: ref,
            personaPrompt: drawingPersonaPrompt,
            onSelected: onDrawingPresetChanged,
          ),
        ),
      ),
      _pluginEntry(
        ref,
        colors,
        pluginId: 'memory',
        icon: Icons.psychology_outlined,
        label: '记忆',
        binding: _BindingSpec(
          label: '角色记忆文档',
          value: memoryDocAvailable ? '' : '开始聊天后可编辑',
          onTap: memoryDocAvailable ? onOpenMemoryDoc : null,
        ),
      ),
      _tavernEntry(context, ref),
      _pluginEntry(
        ref,
        colors,
        pluginId: 'sticker',
        icon: Icons.emoji_emotions_outlined,
        label: '表情包',
      ),
      _pluginEntry(
        ref,
        colors,
        pluginId: 'trigger',
        icon: Icons.favorite_outline,
        label: '主动关怀',
      ),
      _pluginEntry(
        ref,
        colors,
        pluginId: 'time_awareness',
        icon: Icons.schedule_outlined,
        label: '时间感知',
      ),
    ];

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      title: '插件',
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0)
            Divider(height: 0.5, thickness: 0.5, color: colors.divider),
          entries[i],
        ],
      ],
    );
  }

  // ==================== 开关插件行 ====================

  Widget _pluginEntry(
    WidgetRef ref,
    MoeColors colors, {
    required String pluginId,
    required IconData icon,
    required String label,
    _BindingSpec? binding,
  }) {
    final globallyEnabled = _isPluginGloballyEnabled(ref, pluginId);
    final allowed = selectedPluginIds.contains(pluginId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MoeSettingsRow(
          icon: icon,
          label: label,
          subtitle: globallyEnabled ? null : '全局未开启，需先在聊天插件中启用',
          enabled: globallyEnabled,
          showDivider: false,
          trailingType: MoeSettingsRowTrailing.switchControl,
          switchValue: allowed,
          onSwitchChanged: globallyEnabled
              ? (value) => _togglePlugin(pluginId, value)
              : null,
        ),
        if (allowed && globallyEnabled && binding != null)
          _bindingLine(colors, binding),
      ],
    );
  }

  void _togglePlugin(String pluginId, bool value) {
    final next = Set<String>.from(selectedPluginIds);
    if (value) {
      next.add(pluginId);
    } else {
      next.remove(pluginId);
    }
    onPluginIdsChanged(next);
  }

  /// 普通聊天插件恒为全局开启，仅主动关怀仍受全局服务开关约束。
  bool _isPluginGloballyEnabled(WidgetRef ref, String pluginId) {
    if (pluginId != 'trigger') return true;
    return ref.read(appSettingsProvider).value?.autoReplySettings.enabled ??
        false;
  }

  /// 绑定行：缩进到主行文字下方，一行展示当前绑定，点击更换。
  Widget _bindingLine(MoeColors colors, _BindingSpec spec) {
    final enabled = spec.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: spec.onTap,
      child: Padding(
        padding: const EdgeInsets.only(left: 48, right: 12, bottom: 8),
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

  // ==================== 酒馆行（无开关，直接显示绑定预设） ====================

  Widget _tavernEntry(BuildContext context, WidgetRef ref) {
    final presetsAsync = ref.watch(presetRecipeListProvider);
    final presets = presetsAsync.valueOrNull ?? const <PresetRecipeSummary>[];

    return MoeSettingsRow(
      icon: Icons.menu_book_outlined,
      label: '酒馆',
      subtitle: presetsAsync.hasError ? '预设列表读取失败，请到管理页检查' : null,
      showDivider: false,
      trailingType: MoeSettingsRowTrailing.text,
      detailText: presetsAsync.isLoading
          ? '正在加载…'
          : tavernPresetDisplayName(presets, selectedRecipeId),
      onTap: () => showTavernPresetPicker(
        context: context,
        selectedRecipeId: selectedRecipeId,
        onChanged: onRecipeChanged,
      ),
    );
  }

  // ==================== 音色 ====================

  String _voiceDisplayName() {
    final id = boundVoiceId;
    if (id == null || id.isEmpty) return '跟随默认音色配置包';

    for (final preset in voicePresets) {
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
            presets: voicePresets,
            selectedId: boundVoiceId,
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
      onVoiceChanged(null);
    } else {
      onVoiceChanged(selected);
    }
  }

  // ==================== 生图 ====================

  bool get _drawingFollowsDefault {
    final parts = PersonaPromptCodec.parse(drawingPersonaPrompt);
    return (parts.drawingPresetId?.isEmpty ?? true) &&
        (parts.drawingToolPresetName?.isEmpty ?? true) &&
        (parts.drawingArtistPresetName?.isEmpty ?? true);
  }

  String _drawingPresetDisplayName(WidgetRef ref) {
    final selected = ref.watch(roleDrawingPresetProvider(drawingPersonaPrompt));
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

class _BindingSpec {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _BindingSpec({required this.label, required this.value, this.onTap});
}
