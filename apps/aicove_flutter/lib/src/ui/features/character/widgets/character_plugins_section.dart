/// CharacterPluginsSection - 角色编辑页：插件
///
/// 已开启插件是一个统一行高的列表（顺序：音色、生图、记忆、酒馆、表情包、
/// 主动关怀、时间感知），每行只显示当前绑定的预设/入口，不放开关；列表末行
/// 「管理插件」弹出底部弹窗逐项开关，开启后对应行出现在列表里。
/// 酒馆没有按角色开关位，始终在列表中显示绑定预设，也不出现在管理列表里。
/// 没有单独绑定、跟随默认时行尾写「默认」；联网搜索没有可用服务时写「未配置」。
/// 除没有设置页的插件外，每行都能点进对应设置；表情包点开选这个角色能用的
/// 套组；「工作空间」常驻末尾，点开逐个授权这个角色的后台助手能访问和修改的空间。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/mcp/mcp_connector.dart';
import '../../../../features/plugins/mcp/mcp_connector_providers.dart';
import '../../../../features/plugins/packages/package_providers.dart';
import '../../../../features/plugins/plugin_providers.dart';
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/stickers/sticker_library.dart';
import '../../../../features/stickers/sticker_library_provider.dart';
import '../../../../features/stickers/sticker_pack_grants.dart';
import '../../../../features/workspace/domain/workspace_grants.dart';
import '../../../../features/workspace/domain/workspace_models.dart';
import '../../../../features/workspace/workspace_providers.dart';
import '../../../../features/chat/id_gen.dart';
import '../../../../features/plugins/tts/voice_preset_application.dart';
import '../../../shared/animations/parallax_slide_page_route.dart';
import '../../../shared/widgets/index.dart';
import '../../auto_reply/pages/auto_reply_settings_page.dart';
import '../../plugins/pages/sticker_settings_page.dart';
import '../../plugins/pages/time_awareness_plugin_detail_page.dart';
import '../../plugins/pages/voice_preset_editor_page.dart';
import '../../plugins/pages/web_search_plugin_detail_page.dart';
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

  /// 角色名，用于「为这个角色新建」预设的命名
  final String roleName;

  /// 是否可编辑角色记忆文档（仅编辑已有会话时可进入）
  final bool memoryDocAvailable;
  final VoidCallback? onOpenMemoryDoc;

  final ValueChanged<Set<String>> onPluginIdsChanged;
  final ValueChanged<String?> onVoiceChanged;
  final ValueChanged<String?> onDrawingPresetChanged;
  final ValueChanged<String?> onRecipeChanged;

  /// 角色内置的空间授权（[WorkspaceGrants.builtInFor]），常开、不可关。
  final Set<String> builtInWorkspaceIds;

  const CharacterPluginsSection({
    super.key,
    required this.selectedPluginIds,
    required this.boundVoiceId,
    required this.voicePresets,
    required this.drawingPersonaPrompt,
    required this.selectedRecipeId,
    this.roleName = '',
    required this.memoryDocAvailable,
    required this.onOpenMemoryDoc,
    required this.onPluginIdsChanged,
    required this.onVoiceChanged,
    required this.onDrawingPresetChanged,
    required this.onRecipeChanged,
    this.builtInWorkspaceIds = const {},
  });

  @override
  ConsumerState<CharacterPluginsSection> createState() =>
      _CharacterPluginsSectionState();
}

class _CharacterPluginsSectionState
    extends ConsumerState<CharacterPluginsSection> {
  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    final workspaces =
        ref.watch(workspacesProvider).valueOrNull ?? const <WorkspaceInfo>[];
    final packs =
        ref.watch(stickerLibraryProvider).valueOrNull ?? const <StickerPack>[];
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
            roleName: widget.roleName,
          ),
        ),
      ),
      _PluginSpec(
        id: 'memory',
        label: '记忆',
        binding: _BindingSpec(
          value: '',
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
      _PluginSpec(
        id: 'sticker',
        label: '表情包',
        binding: _BindingSpec(
          value: _stickerPackNames(packs),
          onTap: () => _showStickerPackSheet(packs),
        ),
      ),
      _PluginSpec(
        id: 'trigger',
        label: '主动关怀',
        binding: _openPage(const AutoReplySettingsPage()),
      ),
      _PluginSpec(
        id: 'time_awareness',
        label: '时间感知',
        binding: _openPage(const TimeAwarenessPluginDetailPage()),
      ),
      _PluginSpec(
        id: 'web_search',
        label: '联网搜索',
        binding: _openPage(
          const WebSearchPluginDetailPage(),
          value: ref.watch(webSearchPluginConfigProvider).isConfigured
              ? ''
              : _unconfigured,
        ),
      ),
      // 每个 MCP 连接器单独开关；角色未开启时不会拿到它的工具。
      for (final connector in ref.watch(mcpConnectorsConfigProvider).connectors)
        _PluginSpec(
          id: McpToolNaming.pluginIdOf(connector.id),
          label: connector.displayName,
          binding: _BindingSpec(value: _connectorStatus(connector)),
        ),
      // 声明式包同样须由角色显式开启。
      for (final package in ref.watch(aicovePackagesProvider))
        _PluginSpec(id: package.pluginId, label: package.name),
      // 工作空间：这个角色的后台助手能访问和修改哪些空间（ADR0087 第 1 条），
      // 在自己的弹窗里逐个授权，不进管理插件列表。
      _PluginSpec(
        id: _workspacesRowId,
        label: '工作空间',
        alwaysOn: true,
        binding: _BindingSpec(
          value: _grantedWorkspaceNames(workspaces),
          onTap: () => _showWorkspaceSheet(workspaces),
        ),
      ),
    ];

    final active = plugins.where(_isActive).toList();

    return MoeSettingsGroup(
      margin: EdgeInsets.zero,
      children: [
        for (final plugin in active) _enabledRow(colors, plugin),
        MoeSettingsRow(
          key: const ValueKey('manage-plugins'),
          label: '管理插件',
          labelColor: colors.primary,
          trailingType: MoeSettingsRowTrailing.none,
          showDivider: false,
          onTap: () => _showManageSheet([
            for (final p in plugins)
              if (!p.alwaysOn) p,
          ]),
        ),
      ],
    );
  }

  bool _isActive(_PluginSpec plugin) =>
      plugin.alwaysOn || widget.selectedPluginIds.contains(plugin.id);

  // ==================== 已开启插件列表 ====================

  Widget _enabledRow(MoeColors colors, _PluginSpec plugin) {
    final binding = plugin.binding;
    return MoeSettingsRow(
      key: ValueKey('enabled-plugin-${plugin.id}'),
      label: plugin.label,
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

  _BindingSpec _openPage(Widget page, {String value = ''}) => _BindingSpec(
    value: value,
    onTap: () => Navigator.of(
      context,
    ).push(ParallaxSlidePageRoute(page: page)),
  );

  // ==================== 工作空间 ====================

  static const _workspacesRowId = 'workspaces';

  bool _workspaceGranted(String id, Set<String> pluginIds) =>
      widget.builtInWorkspaceIds.contains(id) ||
      pluginIds.contains(WorkspaceGrants.pluginIdOf(id));

  String _grantedWorkspaceNames(List<WorkspaceInfo> workspaces) {
    final names = [
      for (final w in workspaces)
        if (_workspaceGranted(w.id, widget.selectedPluginIds)) w.name,
    ];
    return names.isEmpty ? '未授权' : names.join('、');
  }

  /// 逐个授权空间；内置空间常开，开关只显示不响应。
  Future<void> _showWorkspaceSheet(List<WorkspaceInfo> workspaces) {
    var selected = Set<String>.from(widget.selectedPluginIds);
    return showMoeBottomSheet<void>(
      context: context,
      title: '工作空间',
      showCloseButton: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final colors = context.moeColors;
          if (workspaces.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '还没有空间',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: colors.muted),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '开启的空间，这个角色的后台助手可以读取和修改。',
                    style: TextStyle(fontSize: 13, color: colors.muted),
                  ),
                ),
                for (var i = 0; i < workspaces.length; i++)
                  _switchRow(
                    colors,
                    _PluginSpec(
                      id: WorkspaceGrants.pluginIdOf(workspaces[i].id),
                      label: workspaces[i].name,
                    ),
                    value: _workspaceGranted(workspaces[i].id, selected),
                    showDivider: i < workspaces.length - 1,
                    onToggle: (value) {
                      if (widget.builtInWorkspaceIds.contains(
                        workspaces[i].id,
                      )) {
                        return;
                      }
                      final id = WorkspaceGrants.pluginIdOf(workspaces[i].id);
                      final next = Set<String>.from(selected);
                      value ? next.add(id) : next.remove(id);
                      setSheetState(() => selected = next);
                      widget.onPluginIdsChanged(next);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== 表情包套组 ====================

  /// 选中的、本机还在的套组；为空表示用全部已启用套组（同运行时口径）。
  Set<String> _grantedPackIds(List<StickerPack> packs, Set<String> pluginIds) {
    final granted = StickerPackGrants.of(pluginIds);
    return {
      for (final p in packs)
        if (granted.contains(p.id)) p.id,
    };
  }

  String _stickerPackNames(List<StickerPack> packs) {
    final granted = _grantedPackIds(packs, widget.selectedPluginIds);
    if (granted.isEmpty) return '全部套组';
    return [
      for (final p in packs)
        if (granted.contains(p.id)) p.name,
    ].join('、');
  }

  /// 「全部套组」开着时跟随表情库（以后新加的也能用）；关掉后逐个勾选，
  /// 至少留一个——一个都不想用就关掉表情包插件。
  Future<void> _showStickerPackSheet(List<StickerPack> packs) {
    var selected = Set<String>.from(widget.selectedPluginIds);
    void commit(Set<String> next, StateSetter setSheetState) {
      setSheetState(() => selected = next);
      widget.onPluginIdsChanged(next);
    }

    Set<String> withGrants(Set<String> base, Iterable<String> packIds) => {
      for (final id in base)
        if (!StickerPackGrants.isGrantId(id)) id,
      for (final id in packIds) StickerPackGrants.pluginIdOf(id),
    };

    return showMoeBottomSheet<void>(
      context: context,
      title: '表情包套组',
      showCloseButton: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final colors = context.moeColors;
          final granted = _grantedPackIds(packs, selected);
          final all = granted.isEmpty;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '这个角色只会发开启的套组里的表情。',
                    style: TextStyle(fontSize: 13, color: colors.muted),
                  ),
                ),
                if (packs.isNotEmpty)
                  _switchRow(
                    colors,
                    const _PluginSpec(id: 'sticker-all', label: '全部套组'),
                    value: all,
                    showDivider: true,
                    onToggle: (value) => commit(
                      withGrants(
                        selected,
                        value ? const [] : [for (final p in packs) p.id],
                      ),
                      setSheetState,
                    ),
                  ),
                for (final pack in packs)
                  _switchRow(
                    colors,
                    _PluginSpec(
                      id: StickerPackGrants.pluginIdOf(pack.id),
                      label: pack.enabled ? pack.name : '${pack.name}（已停用）',
                    ),
                    value: all || granted.contains(pack.id),
                    showDivider: true,
                    onToggle: (value) {
                      final next = {
                        ...(all ? {for (final p in packs) p.id} : granted),
                      };
                      value ? next.add(pack.id) : next.remove(pack.id);
                      if (next.isEmpty) {
                        MoeToast.brief(
                          context,
                          '至少留一个套组；不想用表情包可以在管理插件里关掉',
                        );
                        return;
                      }
                      commit(withGrants(selected, next), setSheetState);
                    },
                  ),
                MoeSettingsRow(
                  key: const ValueKey('sticker-manage-library'),
                  label: packs.isEmpty ? '还没有套组，去导入' : '管理表情包',
                  labelColor: colors.primary,
                  trailingType: MoeSettingsRowTrailing.none,
                  showDivider: false,
                  onTap: () => Navigator.of(context).push(
                    ParallaxSlidePageRoute(page: const StickerSettingsPage()),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ==================== 管理插件弹窗 ====================

  /// 弹窗内的开关先改本地副本，每次切换同时回传给编辑页，关掉弹窗即已保存。
  Future<void> _showManageSheet(List<_PluginSpec> plugins) {
    var selected = Set<String>.from(widget.selectedPluginIds);
    return showMoeBottomSheet<void>(
      context: context,
      title: '管理插件',
      showCloseButton: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final colors = context.moeColors;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < plugins.length; i++)
                  _switchRow(
                    colors,
                    plugins[i],
                    value: selected.contains(plugins[i].id),
                    showDivider: i < plugins.length - 1,
                    onToggle: (value) {
                      final next = Set<String>.from(selected);
                      value ? next.add(plugins[i].id) : next.remove(plugins[i].id);
                      setSheetState(() => selected = next);
                      widget.onPluginIdsChanged(next);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _switchRow(
    MoeColors colors,
    _PluginSpec plugin, {
    required bool value,
    required bool showDivider,
    required ValueChanged<bool> onToggle,
  }) {
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
            child: MoeSwitch(
              value: value,
              semanticLabel: plugin.label,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
      onTap: () => onToggle(!value),
    );
  }

  // ==================== MCP 连接器 ====================

  static String _connectorStatus(McpConnector connector) {
    if (!connector.enabled) return '连接器已停用';
    if (connector.tools.isEmpty) return '尚未连接';
    return '${connector.activeTools.length} 个工具';
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
    return _followsDefault;
  }

  // ==================== 音色 ====================

  /// 联网搜索没有可用服务时标出来（插件此时不会生效）。
  static const _unconfigured = '未配置';

  /// 没有单独绑定，跟随全局默认。
  static const _followsDefault = '默认';

  String _voiceDisplayName() {
    final id = widget.boundVoiceId;
    if (id == null || id.isEmpty) return _followsDefault;
    final preset = widget.voicePresets.where((p) => p.id == id).firstOrNull;
    return preset?.name ?? '绑定的预设已丢失，请重新选择';
  }

  Future<void> _showVoicePicker(BuildContext context) async {
    const followGlobalToken = '__follow_global__';
    const createToken = '__create_for_role__';

    final selected = await showMoeBottomSheet<String>(
      context: context,
      title: '选择音色配置包',
      showCloseButton: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final settings = ref.watch(appSettingsProvider).valueOrNull;
          final config = ref.watch(ttsPluginConfigProvider);
          final list = VoicePresetList(
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
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MoeListTile(
                leading: const Icon(Icons.add),
                title: const Text('为这个角色新建'),
                subtitle: const Text('复制当前音色配置包，只给这个角色用'),
                onTap: () => Navigator.of(context).pop(createToken),
              ),
              Flexible(child: list),
            ],
          );
        },
      ),
    );

    if (selected == null || !context.mounted) return;
    if (selected == createToken) {
      await _createVoiceForRole(context);
    } else if (selected == followGlobalToken) {
      widget.onVoiceChanged(null);
    } else {
      widget.onVoiceChanged(selected);
    }
  }

  /// Copies the voice preset this role uses now (bound or default), binds
  /// the copy to this role only and opens it (ADR0092).
  Future<void> _createVoiceForRole(BuildContext context) async {
    try {
      final config = ref.read(ttsPluginConfigProvider);
      final sourceId = widget.boundVoiceId ?? config.defaultVoicePresetId;
      final source = widget.voicePresets
          .where((p) => p.id == sourceId)
          .firstOrNull;
      if (source == null) throw StateError('没有可复制的音色配置包，请先选一个');
      final name = widget.roleName.trim().isEmpty
          ? '新角色'
          : widget.roleName.trim();
      final copy = source.copyWith(
        id: genId('voice'),
        name: '$name · ${source.name}',
        isBuiltIn: false,
      );
      await ref.read(voicePresetApplicationProvider).save(copy);
      widget.onVoiceChanged(copy.id);
      if (!context.mounted) return;
      await Navigator.of(context).push(
        ParallaxSlidePageRoute(page: VoicePresetEditorPage(preset: copy)),
      );
    } catch (e) {
      if (context.mounted) MoeToast.error(context, '新建失败：$e');
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
      data: (preset) => _drawingFollowsDefault ? _followsDefault : preset.name,
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
