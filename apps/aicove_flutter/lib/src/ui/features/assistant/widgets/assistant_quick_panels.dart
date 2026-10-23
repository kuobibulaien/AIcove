import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/assistant/application/assistant_panel_actions.dart';
import '../../../../features/assistant/application/assistant_role_tools.dart';
import '../../../../features/assistant/application/assistant_settings.dart';
import '../../../../features/assistant/application/assistant_settings_tools.dart';
import '../../../../features/assistant/application/assistant_cards.dart'
    show AssistantCardTools;
import '../../../../features/assistant/assistant_panel_providers.dart';
import '../../../../features/assistant/domain/assistant_onboarding.dart'
    show kAicoveAssistantId, providerHasApiKey;
import '../../../../features/chat/conversation_providers.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../../features/chat/domain/persona_prompt_codec.dart';
import '../../../../features/plugins/image/drawing_preset.dart';
import '../../../../features/plugins/image/drawing_preset_provider.dart';
import '../../../../features/plugins/plugin_providers.dart'
    show ttsPluginConfigProvider;
import '../../../../features/plugins/tts/tts_config.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../features/ui_blocks/domain/ui_expression.dart'
    show uiFormatNumber, uiStringify;
import '../../../../features/ui_blocks/domain/ui_saved_state.dart'
    show kUiActionDidMax, uiCleanActionState;
import '../../../shared/widgets/index.dart';
import '../../../shared/widgets/ui_blocks/ui_block_options.dart';
import '../../../shared/widgets/ui_blocks/ui_block_primitives.dart'
    show UiBadge;
import '../../../shared/widgets/ui_blocks/ui_block_style.dart';
import '../../character/pages/contact_edit_page.dart';
import '../../character/services/contact_edit_snapshot_store.dart';
import '../../plugins/pages/drawing_preset_editor_page.dart';
import '../../plugins/pages/voice_preset_editor_page.dart';
import '../../settings/pages/provider_detail_page.dart';

/// Renderers of AIcove酱's quick panels (ADR0094), given to the chat list of
/// the assistant chat only. The lists are read live; the model only names
/// the panel and what to focus on.
final Map<String, UiActionPanelBuilder> kAssistantQuickPanels = {
  'roles': (_, request) => _RolesPanel(request: request),
  'drawing-presets': (_, request) => _DrawingPresetsPanel(request: request),
  'voice-presets': (_, request) => _VoicePresetsPanel(request: request),
  'settings': (_, request) => _SettingsPanel(request: request),
  'providers': (_, request) => _ProvidersPanel(request: request),
};

/// Rows shown before 「显示全部」.
const _collapsedRows = 6;

/// Picked row and history shared by every panel; kept as the block's state
/// so the model is told in the next turn.
mixin _PanelState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  UiActionPanelRequest get request;

  /// The picked row's id and name, kept together; null until the user
  /// picks here (the saved pick shows until then).
  ({String id, String name})? _picked;
  List<String>? _did;
  bool _busy = false;
  bool _expanded = false;

  String? get picked => _picked?.id ?? request.saved['picked'] as String?;

  String? get _pickedName =>
      _picked?.name ?? request.saved['pickedName'] as String?;

  List<String> get did =>
      _did ??
      [for (final item in request.saved['did'] as List? ?? const []) '$item'];

  void pick(String id, String name) {
    setState(
      () => _picked = picked == id ? (id: '', name: '') : (id: id, name: name),
    );
    _store();
  }

  /// Saves through the same cleaning as reading back, so what is stored is
  /// what the model is told.
  void _store() {
    final p = picked;
    request.save?.call(
      uiCleanActionState({
        if (p != null && p.isNotEmpty) ...{
          'picked': p,
          'pickedName': ?_pickedName,
        },
        if (did.isNotEmpty) 'did': did,
      }),
    );
  }

  /// Runs a tap through the assistant's own tool (ADR0094 decision 3).
  Future<void> act(
    String toolName,
    Map<String, dynamic> args, {
    String? done,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    final PanelActionResult result;
    try {
      result = await ref
          .read(assistantPanelActionsProvider)
          .run(
            toolName,
            args,
            confirm: (prompt) async =>
                await showMeoTalkConfirm(
                  context: context,
                  title: prompt.title,
                  message: prompt.detail.isEmpty ? '确定要这样改吗？' : prompt.detail,
                  confirmText: '允许',
                ) ==
                true,
          );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    switch (result) {
      case PanelActionDone(:final change, :final undoable):
        final text = done ?? change;
        final next = [...did, text];
        setState(
          () => _did = next.length <= kUiActionDidMax
              ? next
              : next.sublist(next.length - kUiActionDidMax),
        );
        // Only the record is added; the pick stays whatever it is now.
        _store();
        MoeToast.show(context, undoable ? '$text，可在输入框上方撤销' : text);
      case PanelActionFailed(:final message):
        MoeToast.error(context, message);
      case PanelActionCancelled():
        break;
    }
  }

  void open(Widget page) => MoeWorkspace.open(context, page);

  void askFor(String text) => request.ask?.call(text);

  /// The rows, with 「显示全部」 past [_collapsedRows]; the picked row always
  /// shows.
  List<Widget> rows<E>(
    List<E> items,
    String Function(E item) idOf,
    Widget Function(E item) build,
  ) {
    final style = request.style;
    if (_expanded || items.length <= _collapsedRows + 1) {
      return [for (final item in items) build(item)];
    }
    final shown = [
      for (final (index, item) in items.indexed)
        if (index < _collapsedRows || idOf(item) == picked) item,
    ];
    return [
      for (final item in shown) build(item),
      TextButton(
        onPressed: () => setState(() => _expanded = true),
        child: Text(
          '显示全部（${items.length}）',
          style: style.caption.copyWith(color: style.accent),
        ),
      ),
    ];
  }
}

/// A panel with its title and an empty or loading state.
class _PanelBody extends StatelessWidget {
  const _PanelBody({
    required this.style,
    required this.title,
    required this.children,
    this.hint,
  });

  final UiBlockStyle style;
  final String title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title, style: style.title),
      if (hint != null) ...[
        const SizedBox(height: 2),
        Text(hint!, style: style.caption),
      ],
      const SizedBox(height: 8),
      ...children,
    ],
  );
}

/// One row of a list panel. Tapping picks it; the picked row shows its
/// [actions] underneath.
class _PickRow extends StatelessWidget {
  const _PickRow({
    super.key,
    required this.style,
    required this.title,
    required this.picked,
    required this.onTap,
    this.leading,
    this.subtitle,
    this.badges = const [],
    this.actions = const [],
  });

  final UiBlockStyle style;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final List<Widget> badges;
  final bool picked;
  final VoidCallback onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final border = picked
        ? style.accent.withValues(alpha: 0.55)
        : style.fg.withValues(alpha: 0.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: picked ? style.accent.withValues(alpha: 0.08) : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: style.body.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (subtitle != null && subtitle!.isNotEmpty)
                            Text(
                              subtitle!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: style.caption,
                            ),
                        ],
                      ),
                    ),
                    if (badges.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        flex: 0,
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          alignment: WrapAlignment.end,
                          children: badges,
                        ),
                      ),
                    ],
                  ],
                ),
                if (picked && actions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: actions),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _action(
  String label,
  IconData icon,
  VoidCallback? onTap, {
  bool primary = false,
}) => MoeChoiceChip(
  size: MoeChoiceChipSize.sm,
  label: label,
  icon: icon,
  selected: primary,
  onTap: onTap,
);

Widget _askAction(void Function(String) ask, String text, bool enabled) =>
    _action(
      '交给 AIcove酱',
      Icons.edit_note_rounded,
      enabled ? () => ask(text) : null,
    );

String? _textProp(UiActionPanelRequest request, String key) {
  final value = request.node.text(key)?.trim();
  return value == null || value.isEmpty ? null : value;
}

List<Conversation> _visibleRoles(WidgetRef ref) => [
  for (final role
      in ref.watch(conversationsProvider).valueOrNull ?? const <Conversation>[])
    if (!role.isHidden) role,
];

Conversation? _roleProp(WidgetRef ref, UiActionPanelRequest request) {
  final id = _textProp(request, 'role');
  return id == null
      ? null
      : _visibleRoles(ref).where((role) => role.id == id).firstOrNull;
}

Widget _roleAvatar(Conversation role) => MoeAvatar(
  name: role.displayName,
  avatarUrl: role.avatarUrl,
  characterImage: role.characterImage,
  size: 32,
);

Widget _roleEditPage(Conversation role) => ContactEditPage(
  conversation: role,
  initialSnapshot: ContactEditSnapshot.fromConversation(role),
  editMode: EditMode.editConversation,
);

/// The drawing preset a role uses, as its role page resolves it; null when
/// its legacy binding can no longer be resolved.
DrawingPreset? _drawingPresetOf(
  DrawingPresetCatalog catalog,
  Conversation role,
) {
  try {
    return catalog.resolve(PersonaPromptCodec.parse(role.personaPrompt));
  } on StateError {
    return null;
  }
}

bool _followsDefaultDrawing(Conversation role) {
  final parts = PersonaPromptCodec.parse(role.personaPrompt);
  return [
    parts.drawingPresetId,
    parts.drawingToolPresetName,
    parts.drawingArtistPresetName,
  ].every((value) => value == null || value.trim().isEmpty);
}

// ---- roles ----

class _RolesPanel extends ConsumerStatefulWidget {
  const _RolesPanel({required this.request});
  final UiActionPanelRequest request;

  @override
  ConsumerState<_RolesPanel> createState() => _RolesPanelState();
}

class _RolesPanelState extends ConsumerState<_RolesPanel>
    with _PanelState<_RolesPanel> {
  @override
  UiActionPanelRequest get request => widget.request;

  @override
  Widget build(BuildContext context) {
    final style = request.style;
    final purpose = switch (_textProp(request, 'purpose')) {
      'drawing' => 'drawing',
      'voice' => 'voice',
      _ => 'edit',
    };
    final ids = {
      for (final id in request.node.list('ids')) uiStringify(id).trim(),
    }..remove('');
    final roles =
        [
          for (final role in _visibleRoles(ref))
            if (ids.isEmpty || ids.contains(role.id)) role,
        ]..sort(
          (a, b) =>
              (a.id == kAicoveAssistantId ? 1 : 0) -
              (b.id == kAicoveAssistantId ? 1 : 0),
        );
    final catalog = purpose == 'drawing'
        ? ref.watch(drawingPresetCatalogProvider).valueOrNull
        : null;
    final voices = purpose == 'voice'
        ? ref.watch(ttsPluginConfigProvider).voicePresets
        : const <VoicePreset>[];
    final what = switch (purpose) {
      'drawing' => '绘图预设',
      'voice' => '音色',
      _ => '角色卡',
    };

    Widget row(Conversation role) {
      final drawing = catalog == null ? null : _drawingPresetOf(catalog, role);
      final voice = voices.where((v) => v.id == role.voiceFile).firstOrNull;
      final subtitle = switch (purpose) {
        'drawing' =>
          drawing == null
              ? '绘图预设找不到了，需要重新选'
              : _followsDefaultDrawing(role)
              ? '跟随默认：${drawing.name}'
              : drawing.name,
        'voice' => voice?.name ?? '没有单独绑定音色',
        _ => role.description?.trim(),
      };
      final Widget? openAction = switch (purpose) {
        'drawing' => _action(
          '打开绘图预设',
          Icons.brush_outlined,
          drawing == null
              ? null
              : () => open(DrawingPresetEditorPage(preset: drawing)),
          primary: true,
        ),
        'voice' =>
          voice == null
              ? null
              : _action(
                  '打开音色',
                  Icons.graphic_eq_rounded,
                  () => open(VoicePresetEditorPage(preset: voice)),
                  primary: true,
                ),
        _ => _action(
          '打开角色卡',
          Icons.badge_outlined,
          () => open(_roleEditPage(role)),
          primary: true,
        ),
      };
      return _PickRow(
        key: ValueKey(role.id),
        style: style,
        leading: _roleAvatar(role),
        title: role.displayName,
        subtitle: subtitle,
        picked: picked == role.id,
        onTap: () => pick(role.id, role.displayName),
        actions: [
          ?openAction,
          _askAction(
            askFor,
            '帮我改一下「${role.displayName}」的$what：',
            request.ask != null,
          ),
        ],
      );
    }

    return _PanelBody(
      style: style,
      title: _textProp(request, 'title') ?? '选一个角色',
      hint: '点一下角色，再选怎么改',
      children: roles.isEmpty
          ? [Text('还没有角色', style: style.caption)]
          : rows(roles, (role) => role.id, row),
    );
  }
}

// ---- drawing presets ----

class _DrawingPresetsPanel extends ConsumerStatefulWidget {
  const _DrawingPresetsPanel({required this.request});
  final UiActionPanelRequest request;

  @override
  ConsumerState<_DrawingPresetsPanel> createState() =>
      _DrawingPresetsPanelState();
}

class _DrawingPresetsPanelState extends ConsumerState<_DrawingPresetsPanel>
    with _PanelState<_DrawingPresetsPanel> {
  @override
  UiActionPanelRequest get request => widget.request;

  /// Id of the 「跟随默认」 row.
  static const _followDefault = '-default';

  @override
  Widget build(BuildContext context) {
    final style = request.style;
    final catalog = ref.watch(drawingPresetCatalogProvider).valueOrNull;
    final title = _textProp(request, 'title') ?? '绘图预设';
    if (catalog == null) {
      return _PanelBody(
        style: style,
        title: title,
        children: [Text('正在读取…', style: style.caption)],
      );
    }
    final role = _roleProp(ref, request);
    final users = <String, List<String>>{};
    for (final other in _visibleRoles(ref)) {
      final preset = _drawingPresetOf(catalog, other);
      if (preset != null) (users[preset.id] ??= []).add(other.displayName);
    }
    final current = role == null ? null : _drawingPresetOf(catalog, role);
    final followsDefault = role != null && _followsDefaultDrawing(role);
    final defaultPreset = catalog.presets
        .where((p) => p.id == catalog.defaultPresetId)
        .firstOrNull;

    void useFor(String presetId, String label) => act(
      AssistantRoleTools.setDrawingPreset,
      {'role_id': role!.id, 'preset_id': presetId},
      done: '把「${role.displayName}」的绘图预设换成了$label',
    );

    Widget presetRow(DrawingPreset preset) {
      final inUse = !followsDefault && current?.id == preset.id;
      final usedBy = users[preset.id] ?? const [];
      final rowPicked = picked == preset.id;
      return _PickRow(
        key: ValueKey(preset.id),
        style: style,
        leading: Icon(Icons.brush_outlined, size: 20, color: style.muted),
        title: preset.name,
        subtitle: [
          preset.config.selectedModelId ?? '待配置渠道与模型',
          if (role == null && usedBy.isNotEmpty)
            '${usedBy.take(3).join('、')}${usedBy.length > 3 ? ' 等 ${usedBy.length} 个角色' : ''}在用',
        ].join(' · '),
        badges: [
          if (inUse)
            UiBadge(
              text: '${role!.displayName}在用',
              color: style.accent,
              style: style,
            ),
          if (preset.id == catalog.defaultPresetId)
            UiBadge(text: '默认', color: style.fg, style: style),
        ],
        picked: rowPicked,
        onTap: () => pick(preset.id, preset.name),
        actions: [
          _action(
            '编辑',
            Icons.tune_rounded,
            () => open(DrawingPresetEditorPage(preset: preset)),
            primary: true,
          ),
          if (role != null && !inUse)
            _action(
              '给${role.displayName}用',
              Icons.check_rounded,
              _busy ? null : () => useFor(preset.id, '「${preset.name}」'),
            ),
          _askAction(
            askFor,
            role == null
                ? '帮我改一下绘图预设「${preset.name}」：'
                : '帮我改一下「${role.displayName}」的绘图预设「${preset.name}」：',
            request.ask != null,
          ),
        ],
      );
    }

    return _PanelBody(
      style: style,
      title: title,
      hint: role == null
          ? '点一个预设，再选编辑或交给 AIcove酱'
          : '点一个预设：编辑它，或换给${role.displayName}用',
      children: [
        if (role != null)
          _PickRow(
            key: const ValueKey('follow-default'),
            style: style,
            leading: Icon(
              Icons.auto_awesome_outlined,
              size: 20,
              color: style.muted,
            ),
            title: '跟随默认',
            subtitle: defaultPreset?.name,
            badges: [
              if (followsDefault)
                UiBadge(
                  text: '${role.displayName}在用',
                  color: style.accent,
                  style: style,
                ),
            ],
            picked: picked == _followDefault,
            onTap: () => pick(_followDefault, '跟随默认'),
            actions: [
              if (!followsDefault)
                _action(
                  '给${role.displayName}用',
                  Icons.check_rounded,
                  _busy ? null : () => useFor('', '跟随默认'),
                ),
            ],
          ),
        ...rows(catalog.presets, (p) => p.id, presetRow),
      ],
    );
  }
}

// ---- voice presets ----

class _VoicePresetsPanel extends ConsumerStatefulWidget {
  const _VoicePresetsPanel({required this.request});
  final UiActionPanelRequest request;

  @override
  ConsumerState<_VoicePresetsPanel> createState() => _VoicePresetsPanelState();
}

class _VoicePresetsPanelState extends ConsumerState<_VoicePresetsPanel>
    with _PanelState<_VoicePresetsPanel> {
  @override
  UiActionPanelRequest get request => widget.request;

  static const _unbound = '-unbound';

  @override
  Widget build(BuildContext context) {
    final style = request.style;
    final config = ref.watch(ttsPluginConfigProvider);
    final voices = config.voicePresets;
    final role = _roleProp(ref, request);
    final users = <String, List<String>>{};
    for (final other in _visibleRoles(ref)) {
      final id = other.voiceFile;
      if (id != null && id.isNotEmpty)
        (users[id] ??= []).add(other.displayName);
    }
    final current = role?.voiceFile;
    final unbound = role != null && (current == null || current.isEmpty);
    final defaultVoice = voices
        .where((v) => v.id == config.defaultVoicePresetId)
        .firstOrNull;

    void useFor(String voiceId, String label) => act(
      AssistantRoleTools.setVoice,
      {'role_id': role!.id, 'voice_id': voiceId},
      done: '把「${role.displayName}」的音色换成了$label',
    );

    Widget voiceRow(VoicePreset voice) {
      final inUse = current == voice.id;
      final usedBy = users[voice.id] ?? const [];
      return _PickRow(
        key: ValueKey(voice.id),
        style: style,
        leading: Icon(Icons.graphic_eq_rounded, size: 20, color: style.muted),
        title: voice.name,
        subtitle: [
          voice.synthesis?.modelId ?? '待配置渠道与模型',
          if (role == null && usedBy.isNotEmpty)
            '${usedBy.take(3).join('、')}${usedBy.length > 3 ? ' 等 ${usedBy.length} 个角色' : ''}在用',
        ].join(' · '),
        badges: [
          if (inUse)
            UiBadge(
              text: '${role!.displayName}在用',
              color: style.accent,
              style: style,
            ),
          if (voice.id == config.defaultVoicePresetId)
            UiBadge(text: '默认', color: style.fg, style: style),
          if (voice.isBuiltIn)
            UiBadge(text: '内置', color: style.fg, style: style),
        ],
        picked: picked == voice.id,
        onTap: () => pick(voice.id, voice.name),
        actions: [
          _action(
            '编辑',
            Icons.tune_rounded,
            () => open(VoicePresetEditorPage(preset: voice)),
            primary: true,
          ),
          if (role != null && !inUse)
            _action(
              '给${role.displayName}用',
              Icons.check_rounded,
              _busy ? null : () => useFor(voice.id, '「${voice.name}」'),
            ),
          _askAction(
            askFor,
            role == null
                ? '帮我改一下音色「${voice.name}」：'
                : '帮我改一下「${role.displayName}」的音色「${voice.name}」：',
            request.ask != null,
          ),
        ],
      );
    }

    return _PanelBody(
      style: style,
      title: _textProp(request, 'title') ?? '音色预设',
      hint: role == null
          ? '点一个音色，再选编辑或交给 AIcove酱'
          : '点一个音色：编辑它，或换给${role.displayName}用',
      children: [
        if (role != null)
          _PickRow(
            key: const ValueKey('unbound'),
            style: style,
            leading: Icon(
              Icons.auto_awesome_outlined,
              size: 20,
              color: style.muted,
            ),
            title: '不单独绑定',
            subtitle: defaultVoice == null
                ? '用语音设置里的默认音色'
                : '用默认音色：${defaultVoice.name}',
            badges: [
              if (unbound)
                UiBadge(
                  text: '${role.displayName}在用',
                  color: style.accent,
                  style: style,
                ),
            ],
            picked: picked == _unbound,
            onTap: () => pick(_unbound, '不单独绑定'),
            actions: [
              if (!unbound)
                _action(
                  '给${role.displayName}用',
                  Icons.check_rounded,
                  _busy ? null : () => useFor('', '不单独绑定'),
                ),
            ],
          ),
        if (voices.isEmpty) Text('还没有音色预设', style: style.caption),
        ...rows(voices, (v) => v.id, voiceRow),
      ],
    );
  }
}

// ---- providers ----

class _ProvidersPanel extends ConsumerStatefulWidget {
  const _ProvidersPanel({required this.request});
  final UiActionPanelRequest request;

  @override
  ConsumerState<_ProvidersPanel> createState() => _ProvidersPanelState();
}

class _ProvidersPanelState extends ConsumerState<_ProvidersPanel>
    with _PanelState<_ProvidersPanel> {
  @override
  UiActionPanelRequest get request => widget.request;

  @override
  Widget build(BuildContext context) {
    final style = request.style;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final providers = settings?.providers ?? const [];
    final defaultProvider = settings?.getModelProviderId(
      settings.defaultModelName,
    );

    Widget providerRow(ProviderAuth provider) {
      final name = provider.displayName ?? provider.id;
      final hasKey = providerHasApiKey(provider);
      final models = provider.visibleModels.isEmpty
          ? provider.models
          : provider.visibleModels;
      return _PickRow(
        key: ValueKey(provider.id),
        style: style,
        leading: ProviderAvatar(
          providerName: name,
          size: ProviderAvatarSize.sm,
        ),
        title: name,
        subtitle: '${models.length} 个模型',
        badges: [
          if (provider.id == defaultProvider)
            UiBadge(text: '默认聊天', color: style.accent, style: style),
          if (!provider.enabled)
            UiBadge(text: '未启用', color: style.fg, style: style),
          if (!hasKey)
            UiBadge(text: '没有 Key', color: style.warning, style: style),
        ],
        picked: picked == provider.id,
        onTap: () => pick(provider.id, name),
        actions: [
          _action(
            '打开渠道',
            Icons.open_in_new_rounded,
            () => open(ProviderDetailPage(providerId: provider.id)),
            primary: true,
          ),
          if (!hasKey)
            _action(
              '填 Key',
              Icons.key_rounded,
              _busy
                  ? null
                  : () => act(AssistantCardTools.requestKey, {
                      'provider_id': provider.id,
                    }, done: '在输入框上方放了「$name」的 Key 输入卡片'),
            ),
          _askAction(askFor, '帮我看看渠道「$name」：', request.ask != null),
        ],
      );
    }

    return _PanelBody(
      style: style,
      title: _textProp(request, 'title') ?? '模型渠道',
      hint: '点一个渠道，再选打开或填 Key',
      children: providers.isEmpty
          ? [Text('还没有模型渠道', style: style.caption)]
          : rows(providers, (p) => p.id, providerRow),
    );
  }
}

// ---- settings ----

const _settingsMax = 8;

class _SettingsPanel extends ConsumerStatefulWidget {
  const _SettingsPanel({required this.request});
  final UiActionPanelRequest request;

  @override
  ConsumerState<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<_SettingsPanel>
    with _PanelState<_SettingsPanel> {
  @override
  UiActionPanelRequest get request => widget.request;

  /// Slider values while dragging, by setting key.
  final _dragging = <String, double>{};

  void _set(AssistantSetting setting, Object? value, String shown) => act(
    AssistantSettingsTools.setTool,
    {'key': setting.key, 'value': value},
    done: '把「${setting.label}」改成了$shown',
  );

  @override
  Widget build(BuildContext context) {
    final style = request.style;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final keys = [
      for (final key in request.node.list('keys')) uiStringify(key).trim(),
    ];
    final known = <AssistantSetting>[];
    final unknown = <String>[];
    for (final key in keys) {
      final setting = assistantSettingOf(key);
      if (setting == null) {
        if (key.isNotEmpty) unknown.add(key);
      } else if (!known.contains(setting) && known.length < _settingsMax) {
        known.add(setting);
      }
    }
    final title = _textProp(request, 'title') ?? '设置';
    if (settings == null) {
      return _PanelBody(
        style: style,
        title: title,
        children: [Text('正在读取…', style: style.caption)],
      );
    }
    return _PanelBody(
      style: style,
      title: title,
      hint: '改了马上生效，可在输入框上方撤销',
      children: [
        for (final (index, setting) in known.indexed) ...[
          if (index > 0) Divider(height: 18, thickness: 0.5, color: style.line),
          _row(setting, settings, style),
        ],
        if (known.isEmpty) Text('没有能在这里改的设置项', style: style.caption),
        if (unknown.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('认不出的设置项：${unknown.join('、')}', style: style.caption),
        ],
      ],
    );
  }

  Widget _row(
    AssistantSetting setting,
    AppSettings settings,
    UiBlockStyle style,
  ) {
    final value = setting.read(settings);
    final enabled = !_busy;
    Widget labeled(Widget control, {String? trailing}) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(setting.label, style: style.small)),
            if (trailing != null)
              Text(
                trailing,
                style: style.small.copyWith(fontWeight: FontWeight.w600),
              ),
          ],
        ),
        const SizedBox(height: 6),
        control,
      ],
    );
    switch (setting.type) {
      case 'bool':
        return Row(
          children: [
            Expanded(child: Text(setting.label, style: style.small)),
            MoeSwitch(
              value: value == true,
              enabled: enabled,
              onChanged: (next) => _set(setting, next, next ? '开' : '关'),
            ),
          ],
        );
      case 'enum':
        final options = setting.options!.entries.toList();
        return labeled(
          UiChoices(
            labels: [for (final o in options) o.value],
            selected: {
              for (final (i, o) in options.indexed)
                if (o.key == value) i,
            },
            onTap: enabled
                ? (i) {
                    if (options[i].key != value)
                      _set(setting, options[i].key, options[i].value);
                  }
                : null,
            style: style,
            segmented: true,
          ),
        );
      case 'number' when setting.min != null && setting.max != null:
        final min = setting.min!.toDouble();
        final max = setting.max!.toDouble();
        final shown =
            (_dragging[setting.key] ?? (value as num?)?.toDouble() ?? min)
                .clamp(min, max);
        return labeled(
          MoeSlider(
            value: shown,
            min: min,
            max: max,
            divisions: ((max - min) * 20).round().clamp(1, 200),
            onChanged: enabled
                ? (v) => setState(() => _dragging[setting.key] = v)
                : null,
            onChangeEnd: enabled
                ? (v) {
                    final clean = (v * 100).round() / 100;
                    setState(() => _dragging.remove(setting.key));
                    if (clean != value)
                      _set(setting, clean, uiFormatNumber(clean));
                  }
                : null,
          ),
          trailing: uiFormatNumber((shown * 100).round() / 100),
        );
      case 'string' when setting.key.startsWith('model.'):
        final label = value == null || '$value'.isEmpty
            ? (setting.nullable ? '跟随默认' : '未设置')
            : '$value';
        return labeled(
          Align(
            alignment: Alignment.centerLeft,
            child: MoeChoiceChip(
              size: MoeChoiceChipSize.sm,
              label: label,
              icon: Icons.unfold_more_rounded,
              selected: false,
              onTap: enabled
                  ? () => _pickModel(setting, settings, value as String?)
                  : null,
            ),
          ),
        );
      default:
        return labeled(
          _TextSetting(
            key: ValueKey(setting.key),
            value: value == null ? '' : '$value',
            number: setting.type == 'integer' || setting.type == 'number',
            enabled: enabled,
            style: style,
            onSave: (text) {
              final trimmed = text.trim();
              final Object? next = switch (setting.type) {
                'integer' => int.tryParse(trimmed),
                'number' => double.tryParse(trimmed),
                _ => trimmed,
              };
              if (next == null) {
                MoeToast.error(context, '请填数字');
                return;
              }
              _set(setting, next, trimmed.isEmpty ? '（清空）' : trimmed);
            },
          ),
        );
    }
  }

  /// Chat models of channels that can take them: enabled, chat-capable and
  /// with a key; the tool checks the pick again.
  Future<void> _pickModel(
    AssistantSetting setting,
    AppSettings settings,
    String? current,
  ) async {
    final models = <String>[
      for (final provider in settings.providers)
        if (provider.enabled &&
            provider.capabilities.contains('chat') &&
            providerHasApiKey(provider))
          for (final model
              in provider.visibleModels.isEmpty
                  ? provider.models
                  : provider.visibleModels)
            settings.buildModelRef(provider.id, model),
    ];
    final picked = await showMoeBottomSheet<String>(
      context: context,
      title: setting.label,
      showCloseButton: true,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          if (setting.nullable)
            MoeListTile(
              title: const Text('跟随默认'),
              trailing: current == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheet, ''),
            ),
          for (final model in models)
            MoeListTile(
              title: Text(model),
              trailing: model == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheet, model),
            ),
          if (models.isEmpty)
            const MoeListTile(title: Text('没有可用的模型：先给渠道填 Key')),
        ],
      ),
    );
    if (picked == null || !mounted || picked == (current ?? '')) return;
    _set(setting, picked, picked.isEmpty ? '跟随默认' : picked);
  }
}

class _TextSetting extends StatefulWidget {
  const _TextSetting({
    super.key,
    required this.value,
    required this.number,
    required this.enabled,
    required this.style,
    required this.onSave,
  });

  final String value;
  final bool number;
  final bool enabled;
  final UiBlockStyle style;
  final ValueChanged<String> onSave;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_TextSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            keyboardType: widget.number ? TextInputType.number : null,
            style: style.small,
            decoration: uiInputDecoration(style),
            onSubmitted: widget.onSave,
          ),
        ),
        const SizedBox(width: 8),
        MoeChoiceChip(
          size: MoeChoiceChipSize.sm,
          label: '保存',
          selected: false,
          onTap: widget.enabled ? () => widget.onSave(_controller.text) : null,
        ),
      ],
    );
  }
}
