import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ReversibleChange, ToolCallScope, ToolEffect;

import '../../agent_context/data/silly_tavern_preset_store.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_plugins/file_change_journal.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import 'assistant_review.dart';

/// Plugins a role card can switch, as on the role edit page. MCP
/// connectors, packages and workspace grants are kept as they are.
const kAssistantRolePlugins = <String, String>{
  'memory': '记忆库',
  'trigger': '主动关怀',
  'sticker': '表情包',
  'tts': '语音',
  'image': '绘图',
  'time_awareness': '时间感知',
  'web_search': '联网搜索',
};

/// Plugins that send chat content to a service the role did not use before;
/// turning one on is a major decision.
const _externalPlugins = {'web_search'};

/// Role storage the write tools go through: the same domain service as the
/// role edit page.
abstract interface class AssistantRoleStore {
  /// The current roles without waiting; used to rate risk synchronously.
  /// It may trail a write by a moment, which is fine for calls a model round
  /// apart; reads before writing go through [load].
  List<Conversation> snapshot();

  Future<List<Conversation>> load();

  /// Writes the given [RoleField] keys of [roleId]; a null value clears an
  /// optional field, and for `enabled_plugins` means every plugin.
  Future<void> edit(String roleId, Map<String, Object?> fields);

  /// Creates an empty role and returns its id.
  Future<String> create();

  /// Moves a role to the trash.
  Future<void> delete(String roleId);

  /// [edit], only if [test] still holds for the stored role; checked and
  /// written in one turn of the store's queue. False when it does not hold.
  Future<bool> editIf(
    String roleId,
    bool Function(Conversation role) test,
    Map<String, Object?> fields,
  );

  /// [delete], only if [test] holds for the stored role and its message
  /// count, in one turn of the queue.
  Future<bool> deleteIf(
    String roleId,
    bool Function(Conversation role, int messageCount) test,
  );
}

/// Editable role fields as the tools and the change journal name them.
abstract final class RoleField {
  static const displayName = 'display_name';
  static const description = 'description';
  static const personaPrompt = 'persona_prompt';
  static const customDrawingPrompt = 'custom_drawing_prompt';
  static const selfAddress = 'self_address';
  static const addressUser = 'address_user';
  static const enabledPlugins = 'enabled_plugins';
  static const recipeId = 'recipe_id';
  static const avatarUrl = 'avatar_url';
  static const characterImage = 'character_image';
  static const chatBackground = 'chat_background';
  static const voiceFile = 'voice_file';
  static const thinkingLevels = 'thinking_levels';
  static const pinned = 'pinned';
  static const muted = 'muted';

  /// This chat's display style: `bubble`, `document`, or null to follow the
  /// default.
  static const displayStyle = 'display_style';

  /// Mask and blur of the chat's own wallpaper; null uses the default.
  static const wallpaperMask = 'wallpaper_mask';
  static const wallpaperBlur = 'wallpaper_blur';

  /// The role's drawing preset binding: `{id?, tool?, artist?}` (the last
  /// two are legacy bindings by name), null to follow the default preset.
  static const drawingPreset = 'drawing_preset';

  static const labels = {
    displayName: '名字',
    description: '简介',
    personaPrompt: '人设提示词',
    customDrawingPrompt: '自定义绘图提示',
    selfAddress: '自称',
    addressUser: '称呼用户',
    enabledPlugins: '插件选择',
    recipeId: '酒馆预设',
    avatarUrl: '头像',
    characterImage: '立绘',
    chatBackground: '聊天壁纸',
    voiceFile: '音色',
    thinkingLevels: '思考档位',
    pinned: '置顶',
    muted: '免打扰',
    displayStyle: '聊天样式',
    wallpaperMask: '聊天壁纸遮罩',
    wallpaperBlur: '聊天壁纸模糊',
    drawingPreset: '绘图预设',
  };

  static Object? read(Conversation role, String key) {
    String? text(String? value) =>
        (value == null || value.trim().isEmpty) ? null : value;
    return switch (key) {
      displayName => role.displayName,
      description => text(role.description),
      personaPrompt => PersonaPromptCodec.parse(role.personaPrompt).userPrompt,
      customDrawingPrompt => text(
        PersonaPromptCodec.parse(role.personaPrompt).customDrawingPrompt,
      ),
      selfAddress => text(role.selfAddress),
      addressUser => text(role.addressUser),
      enabledPlugins => role.enabledPlugins,
      recipeId => text(role.recipeId),
      avatarUrl => text(role.avatarUrl),
      characterImage => text(role.characterImage),
      // The picture and how it is framed move together.
      chatBackground => text(role.chatBackgroundImage) == null
          ? null
          : {
              'image': role.chatBackgroundImage,
              'framing': role.chatBackgroundFraming,
            },
      voiceFile => text(role.voiceFile),
      thinkingLevels => {
        for (final MapEntry(:key, :value) in role.thinkingLevels.entries)
          key: value.name,
      },
      pinned => role.isPinned,
      muted => role.isMuted,
      displayStyle => role.chatDisplayStyle?.name,
      wallpaperMask => role.chatBackgroundMaskOpacity,
      wallpaperBlur => role.chatBackgroundBlurSigma,
      drawingPreset => _drawingBinding(role),
      _ => throw ArgumentError.value(key, 'key', '未知字段'),
    };
  }

  static bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  static Map<String, String>? _drawingBinding(Conversation role) {
    final parts = PersonaPromptCodec.parse(role.personaPrompt);
    final binding = {
      for (final (key, value) in [
        ('id', parts.drawingPresetId),
        ('tool', parts.drawingToolPresetName),
        ('artist', parts.drawingArtistPresetName),
      ])
        if (value != null && value.trim().isNotEmpty) key: value.trim(),
    };
    return binding.isEmpty ? null : binding;
  }
}

/// Change kinds written to the journal by the assistant.
abstract final class AssistantChangeKind {
  static const role = 'assistant.role';
  static const roleCreated = 'assistant.role_created';
  static const presetItem = 'assistant.preset_item';
  static const regexAuthorization = 'assistant.regex_authorization';
}

/// Appliers that write the assistant's changes back for undo.
Map<String, ChangeApplier> assistantChangeAppliers({
  required AssistantRoleStore roles,
  required SillyTavernPresetStore presets,
}) => {
  AssistantChangeKind.role: _RoleApplier(roles),
  AssistantChangeKind.roleCreated: _RoleCreatedApplier(roles),
  AssistantChangeKind.presetItem: _PresetItemApplier(presets),
  AssistantChangeKind.regexAuthorization: _RegexAuthorizationApplier(presets),
};

/// Write tools of the AIcove assistant (ADR0073, batch T3). Every change goes
/// through the change journal so the user can undo it; how much review it
/// needs is [riskOf].
///
/// Roles in the privacy space cannot be read or changed.
class AssistantWriteTools {
  AssistantWriteTools({
    required this.roles,
    required this.presets,
    required this.journal,
    this.onChanged,
  });

  final AssistantRoleStore roles;
  final SillyTavernPresetStore presets;
  final FileChangeJournal journal;

  /// Called after every recorded change, so the undo list can refresh.
  final void Function()? onChanged;

  static const updateRole = 'aicove_update_role';
  static const createRole = 'aicove_create_role';
  static const setRolePlugins = 'aicove_set_role_plugins';
  static const bindPreset = 'aicove_bind_preset';
  static const togglePresetItem = 'aicove_toggle_preset_item';
  static const authorizeRegex = 'aicove_authorize_regex';

  AssistantRisk? riskOf(String toolName, Map<String, dynamic> args) =>
      switch (toolName) {
        updateRole ||
        createRole ||
        bindPreset ||
        authorizeRegex => AssistantRisk.review,
        togglePresetItem => AssistantRisk.reversible,
        setRolePlugins => _pluginRisk(args),
        _ => null,
      };

  /// Key of the note the plugin rating leaves in the call's [ToolCallScope]:
  /// what the gate (and then the approval port) saw, so the write can tell
  /// whether the approval covers the role as it is now. The scope belongs to
  /// one execution; nothing is shared between calls.
  static const _ratingNote = #assistantPluginRating;

  AssistantRisk _pluginRisk(Map<String, dynamic> args) {
    final role = _visible(roles.snapshot(), args['role_id']);
    // Not in the list yet (just created) or gone: assume the worst.
    final risk = role == null
        ? AssistantRisk.major
        : _pluginRiskFor(role, args);
    ToolCallScope.current?.notes[_ratingNote] = (
      args: jsonEncode(args),
      risk: risk,
      plugins: role?.enabledPlugins,
    );
    return risk;
  }

  static AssistantRisk _pluginRiskFor(
    Conversation role,
    Map<String, dynamic> args,
  ) {
    final before = _effectivePlugins(role.enabledPlugins);
    final after = _effectivePlugins(_requestedPlugins(role, args));
    final added = after.difference(before);
    return added.any(_externalPlugins.contains)
        ? AssistantRisk.major
        : AssistantRisk.reversible;
  }

  /// What the user sees when a call needs their approval.
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final role = _visible(roles.snapshot(), args['role_id']);
    final name = role == null ? '' : '「${role.displayName}」';
    String fields() => [
      for (final key in RoleField.labels.keys)
        if (args.containsKey(key)) RoleField.labels[key]!,
    ].join('、');
    String preview(Object? value) {
      final text = (value ?? '').toString().trim();
      return text.length <= 200 ? text : '${text.substring(0, 200)}…';
    }

    return switch (toolName) {
      updateRole => ApprovalPrompt(
        title: '修改角色$name',
        detail: [
          '要改：${fields()}',
          if (args[RoleField.personaPrompt] case final prompt?)
            '新的人设提示词：${preview(prompt)}',
        ].join('\n'),
      ),
      createRole => ApprovalPrompt(
        title: '新建角色「${args['name'] ?? ''}」',
        detail: preview(args[RoleField.personaPrompt]),
      ),
      setRolePlugins => ApprovalPrompt(
        title: '更改角色$name的插件',
        detail: args['all'] == true
            ? '开启全部插件（包括联网搜索：聊天内容会用于联网搜索请求）'
            : '开启：${[for (final id in _ids(args['plugins'])) kAssistantRolePlugins[id] ?? id].join('、')}'
                  '（联网搜索会把聊天内容用于搜索请求）',
      ),
      bindPreset => ApprovalPrompt(
        title: '更换角色$name的酒馆预设',
        detail: '预设 id：${args['preset_id'] ?? '解除绑定'}',
      ),
      authorizeRegex => ApprovalPrompt(
        title: args['authorized'] == true ? '授权预设正则' : '取消预设正则授权',
        detail: '预设 id：${args['preset_id'] ?? ''}',
      ),
      _ => ApprovalPrompt(title: '执行 $toolName', detail: jsonEncode(args)),
    };
  }

  List<AITool> tools() => [
    _tool(
      updateRole,
      '修改一个已有角色卡的字段。只传要改的字段；可选文本字段传空字符串表示清空。'
      '默认直接生效，用户可以撤销。',
      {
        'role_id': _string('aicove_list_roles 给出的角色 id'),
        RoleField.displayName: _string('名字'),
        RoleField.personaPrompt: _string('完整的新人设提示词（整体替换，不是追加）'),
        RoleField.selfAddress: _string('角色的自称'),
        RoleField.addressUser: _string('角色对用户的称呼'),
      },
      ['role_id'],
      _updateRole,
    ),
    _tool(
      createRole,
      '新建一个角色卡。新角色默认不开任何插件，需要的话再用 aicove_set_role_plugins 开启。'
      '默认直接生效，用户可以撤销（撤销会把它移进回收站）。',
      {
        'name': _string('名字'),
        RoleField.personaPrompt: _string('人设提示词'),
        RoleField.selfAddress: _string('角色的自称'),
        RoleField.addressUser: _string('角色对用户的称呼'),
      },
      ['name', RoleField.personaPrompt],
      _createRole,
    ),
    _tool(
      setRolePlugins,
      '设置角色开启哪些插件。all=true 表示全部插件；否则 plugins 列出要开启的全部插件 id'
      '（${[for (final e in kAssistantRolePlugins.entries) '${e.key}=${e.value}'].join('，')}）。'
      'MCP 连接器、空间授权保持原样。开启联网搜索默认直接生效。',
      {
        'role_id': _string('角色 id'),
        'all': {'type': 'boolean', 'description': '是否开启全部插件'},
        'plugins': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要开启的插件 id（all=true 时忽略）',
        },
      },
      ['role_id'],
      _setRolePlugins,
    ),
    _tool(
      bindPreset,
      '给角色绑定一个酒馆预设，preset_id 传空字符串表示解除绑定（回到全局默认预设或 AIcove 自己的装配）。'
      '默认直接生效，用户可以撤销。',
      {
        'role_id': _string('角色 id'),
        'preset_id': _string('aicove_list_presets 给出的预设 id；空字符串表示解除绑定'),
      },
      ['role_id', 'preset_id'],
      _bindPreset,
    ),
    _tool(
      togglePresetItem,
      '开关酒馆预设里的一项：kind=prompt（提示词条目，item_id 用 identifier）、'
      'regex（正则脚本）、world_book（整本世界书）、world_entry（世界书条目，需要 book_id）。'
      'id 都来自 aicove_read_preset。直接生效，用户可以撤销。',
      {
        'preset_id': _string('预设 id'),
        'kind': {
          'type': 'string',
          'enum': ['prompt', 'regex', 'world_book', 'world_entry'],
        },
        'item_id': _string('条目 id'),
        'book_id': _string('世界书 id（kind=world_entry 时必填）'),
        'enabled': {'type': 'boolean'},
      },
      ['preset_id', 'kind', 'item_id', 'enabled'],
      _togglePresetItem,
    ),
    _tool(
      authorizeRegex,
      '授权或取消授权一个预设的正则脚本；未授权时该预设的正则全部不执行。'
      '默认直接生效，用户可以撤销。',
      {
        'preset_id': _string('预设 id'),
        'authorized': {'type': 'boolean'},
      },
      ['preset_id', 'authorized'],
      _authorizeRegex,
    ),
  ];

  static Map<String, Object> _string(String description) => {
    'type': 'string',
    'description': description,
  };

  AITool _tool(
    String name,
    String description,
    Map<String, Object> properties,
    List<String> required,
    Future<Map<String, Object?>> Function(Map<String, dynamic> args) run,
  ) => AITool(
    name: name,
    description: description,
    parameters: const {},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
    effect: ToolEffect.write,
    handler: (args) async {
      try {
        return jsonEncode(await run(args));
      } on _Invalid catch (error) {
        return jsonEncode({'error': 'invalid', 'message': error.message});
      } on StateError catch (error) {
        return jsonEncode({'error': 'failed', 'message': error.message});
      }
    },
  );

  static Conversation? _visible(List<Conversation> list, Object? id) {
    final roleId = (id ?? '').toString().trim();
    for (final role in list) {
      if (role.id == roleId && !role.isHidden) return role;
    }
    return null;
  }

  Future<Conversation> _role(Map<String, dynamic> args) async =>
      _visible(await roles.load(), args['role_id']) ??
      (throw _Invalid('没有 id 为「${args['role_id']}」的角色'));

  Future<Map<String, Object?>> _record(
    String toolName,
    String kind,
    String description,
    Map<String, Object?> before,
    Map<String, Object?> after,
  ) async {
    await journal.commit(
      toolName,
      ReversibleChange(
        kind: kind,
        description: description,
        before: before,
        after: after,
      ),
    );
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }

  /// With [guard], the write happens only if the stored role still passes
  /// it, checked in the same transaction as the write; the record is added
  /// after the write.
  Future<Map<String, Object?>> _editRole(
    String toolName,
    Conversation role,
    Map<String, Object?> fields, {
    bool Function(Conversation current)? guard,
  }) async {
    final changed = {
      for (final MapEntry(:key, :value) in fields.entries)
        if (!RoleField.same(RoleField.read(role, key), value)) key: value,
    };
    if (changed.isEmpty) return {'ok': true, 'change': '没有变化'};
    final labels = [for (final key in changed.keys) RoleField.labels[key]!];
    final description = '改了「${role.displayName}」的${labels.join('、')}';
    final before = {
      'role_id': role.id,
      for (final key in changed.keys) key: RoleField.read(role, key),
    };
    final after = {'role_id': role.id, ...changed};
    if (guard == null) {
      return _record(
        toolName,
        AssistantChangeKind.role,
        description,
        before,
        after,
      );
    }
    // The record goes first, as in [FileChangeJournal.commit], and stays
    // only if the guarded write lands.
    final entry = await journal.commitIf(
      toolName,
      ReversibleChange(
        kind: AssistantChangeKind.role,
        description: description,
        before: before,
        after: after,
      ),
      () => roles.editIf(role.id, guard, changed),
    );
    if (entry == null) throw _Invalid('角色刚刚有变化，请重新调用一次');
    onChanged?.call();
    return {'ok': true, 'change': description, 'undo': '用户可以在聊天页撤销这次修改'};
  }

  /// Edits [fields] of a visible role through the undo journal, for tool
  /// groups outside this class. Fails with a [StateError] the tool reports.
  /// With [guarded], the write lands only while the fields still hold what
  /// the change records as `before`.
  Future<Map<String, Object?>> editRole(
    String toolName,
    String roleId,
    Map<String, Object?> fields, {
    bool guarded = false,
  }) async {
    final role =
        _visible(await roles.load(), roleId) ??
        (throw StateError('没有 id 为「$roleId」的角色'));
    return _editRole(
      toolName,
      role,
      fields,
      guard: guarded
          ? (current) => fields.keys.every(
              (key) => RoleField.same(
                RoleField.read(current, key),
                RoleField.read(role, key),
              ),
            )
          : null,
    );
  }

  static String? _optionalText(Object? value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  Future<Map<String, Object?>> _updateRole(Map<String, dynamic> args) async {
    final role = await _role(args);
    if (args.containsKey(RoleField.description))
      throw _Invalid(_descriptionNotSaved);
    if (args.containsKey(RoleField.customDrawingPrompt)) {
      throw _Invalid(
        '角色的绘图要求已并入绘图预设：用 aicove_read_role 看它的 drawing_preset_id，'
        '再用 aicove_add_prompt_section／aicove_edit_prompt_section 改这个预设的专属节',
      );
    }
    for (final key in RoleField.labels.keys) {
      if (args.containsKey(key) && args[key] is! String) {
        throw _Invalid('${RoleField.labels[key]}应为文本');
      }
    }
    final fields = <String, Object?>{};
    for (final key in const [
      RoleField.selfAddress,
      RoleField.addressUser,
    ]) {
      if (args.containsKey(key)) fields[key] = _optionalText(args[key]);
    }
    for (final key in const [RoleField.displayName, RoleField.personaPrompt]) {
      if (!args.containsKey(key)) continue;
      fields[key] =
          _optionalText(args[key]) ??
          (throw _Invalid('${RoleField.labels[key]}不能为空'));
    }
    if (fields.isEmpty) throw _Invalid('没有要改的字段');
    return _editRole(updateRole, role, fields);
  }

  Future<Map<String, Object?>> _createRole(Map<String, dynamic> args) async {
    // Check every field before anything is created.
    for (final key in const [
      'name',
      RoleField.personaPrompt,
      RoleField.selfAddress,
      RoleField.addressUser,
    ]) {
      final value = args[key];
      if (value != null && value is! String) {
        throw _Invalid('${RoleField.labels[key] ?? '名字'}应为文本');
      }
    }
    final name = _optionalText(args['name']) ?? (throw _Invalid('名字不能为空'));
    final prompt =
        _optionalText(args[RoleField.personaPrompt]) ??
        (throw _Invalid('人设提示词不能为空'));
    final id = await roles.create();
    await roles.edit(id, {
      RoleField.displayName: name,
      RoleField.personaPrompt: prompt,
      RoleField.selfAddress: _optionalText(args[RoleField.selfAddress]),
      RoleField.addressUser: _optionalText(args[RoleField.addressUser]),
      // New roles start with the default plugins, as on the role edit page.
      RoleField.enabledPlugins: kDefaultRolePluginIds,
    });
    const description = '新建了角色';
    final created = _visible(await roles.load(), id);
    await journal.append(
      createRole,
      ReversibleChange(
        kind: AssistantChangeKind.roleCreated,
        description: '$description「$name」',
        before: {'role_id': id, 'exists': false},
        // The created card, so the undo stops once the user edits it.
        after: {
          'role_id': id,
          'exists': true,
          if (created != null) ...{
            'fields': {
              for (final key in RoleField.labels.keys)
                key: RoleField.read(created, key),
            },
            // Every save of the card moves this, including the avatar,
            // wallpaper and voice that the fields above leave out.
            'updated_at': created.updatedAt.millisecondsSinceEpoch,
          },
        },
      ),
    );
    onChanged?.call();
    return {
      'ok': true,
      'role_id': id,
      'change': '$description「$name」',
      'undo': '用户可以在聊天页撤销这次修改',
    };
  }

  static List<String> _ids(Object? value) => [
    if (value is List)
      for (final id in value) id.toString().trim(),
  ];

  static bool _keptAsIs(String id) => !kAssistantRolePlugins.containsKey(id);

  static Set<String> _effectivePlugins(List<String>? enabled) =>
      enabled == null ? kAssistantRolePlugins.keys.toSet() : enabled.toSet();

  /// The plugin selection [args] asks for, keeping connectors, packages and
  /// workspace grants; null is every plugin, stored the way the edit page
  /// stores it.
  static List<String>? _requestedPlugins(
    Conversation role,
    Map<String, dynamic> args,
  ) {
    final kept = [
      for (final id in role.enabledPlugins ?? const <String>[])
        if (_keptAsIs(id)) id,
    ];
    if (args['all'] == true) {
      return kept.isEmpty ? null : [...kAssistantRolePlugins.keys, ...kept];
    }
    final wanted = _ids(args['plugins']).toSet();
    return [
      for (final id in kAssistantRolePlugins.keys)
        if (wanted.contains(id)) id,
      ...kept,
    ];
  }

  Future<Map<String, Object?>> _setRolePlugins(
    Map<String, dynamic> args,
  ) async {
    final role = await _role(args);
    if (args.containsKey('all') && args['all'] is! bool) {
      throw _Invalid('all 应为 true 或 false');
    }
    if (args['all'] != true) {
      final plugins = args['plugins'];
      if (plugins is! List || plugins.any((id) => id is! String)) {
        throw _Invalid('plugins 应为插件 id 的列表');
      }
      final unknown = [
        for (final id in _ids(args['plugins']))
          if (!kAssistantRolePlugins.containsKey(id)) id,
      ];
      if (unknown.isNotEmpty) {
        throw _Invalid(
          '不认识的插件 id：${unknown.join('、')}；可用：${kAssistantRolePlugins.keys.join('、')}',
        );
      }
    }
    // The gate rated this call from the list state, which may trail the
    // database, and the role may change between rating and writing. A call
    // not approved as major may neither turn on an external plugin nor
    // write over a selection other than the one it was rated on; the retry
    // is rated again from fresh state.
    final scope = ToolCallScope.current;
    final note = scope?.notes[_ratingNote];
    final rated =
        note is ({String args, AssistantRisk risk, List<String>? plugins}) &&
            note.args == jsonEncode(args)
        ? note
        : null;
    // Major is only ever let through by the user, so a major rating in this
    // call's own scope, approved, is the user's consent for it.
    final approvedMajor =
        rated?.risk == AssistantRisk.major &&
        scope?.outcome == GateOutcome.approved;
    bool covered(Conversation current) =>
        AssistantToolGate.unrestricted ||
        approvedMajor || _pluginRiskFor(current, args) != AssistantRisk.major;
    if (!covered(role) ||
        (rated != null &&
            !RoleField.same(rated.plugins, role.enabledPlugins))) {
      throw _Invalid('角色的插件刚刚有变化，请重新调用一次');
    }
    // Checked once more inside the write itself, so a change landing
    // between this check and the write is caught too.
    return _editRole(
      setRolePlugins,
      role,
      {RoleField.enabledPlugins: _requestedPlugins(role, args)},
      guard: (current) =>
          RoleField.same(current.enabledPlugins, role.enabledPlugins) &&
          covered(current),
    );
  }

  Future<SillyTavernPreset> _preset(Object? id) async {
    final presetId = (id ?? '').toString().trim();
    return await presets.get(presetId) ??
        (throw _Invalid('没有 id 为「$presetId」的预设'));
  }

  Future<Map<String, Object?>> _bindPreset(Map<String, dynamic> args) async {
    final role = await _role(args);
    final presetId = _optionalText(args['preset_id']);
    if (presetId != null) await _preset(presetId);
    return _editRole(bindPreset, role, {RoleField.recipeId: presetId});
  }

  Future<Map<String, Object?>> _togglePresetItem(
    Map<String, dynamic> args,
  ) async {
    final enabled = args['enabled'];
    if (enabled is! bool) throw _Invalid('enabled 应为 true 或 false');
    final preset = await _preset(args['preset_id']);
    final kind = (args['kind'] ?? '').toString();
    final itemId = (args['item_id'] ?? '').toString().trim();
    final bookId = _optionalText(args['book_id']);
    final item = {
      'preset_id': preset.id,
      'kind': kind,
      'item_id': itemId,
      'book_id': ?bookId,
    };
    final current =
        _PresetItemApplier.enabledOf(preset, item) ??
        (throw _Invalid('预设「${preset.name}」里没有这一项（$kind $itemId）'));
    if (current == enabled) return {'ok': true, 'change': '没有变化'};
    final label = switch (kind) {
      'prompt' => '提示词条目',
      'regex' => '正则',
      'world_book' => '世界书',
      _ => '世界书条目',
    };
    return _record(
      togglePresetItem,
      AssistantChangeKind.presetItem,
      '${enabled ? '开启' : '关闭'}了预设「${preset.name}」的$label「${_PresetItemApplier.nameOf(preset, item)}」',
      {...item, 'enabled': current},
      {...item, 'enabled': enabled},
    );
  }

  Future<Map<String, Object?>> _authorizeRegex(
    Map<String, dynamic> args,
  ) async {
    final preset = await _preset(args['preset_id']);
    final authorized = args['authorized'];
    if (authorized is! bool) throw _Invalid('authorized 应为 true 或 false');
    if (preset.regexAuthorized == authorized) {
      return {'ok': true, 'change': '没有变化'};
    }
    return _record(
      authorizeRegex,
      AssistantChangeKind.regexAuthorization,
      '${authorized ? '授权' : '取消授权'}了预设「${preset.name}」的正则',
      {'preset_id': preset.id, 'authorized': preset.regexAuthorized},
      {'preset_id': preset.id, 'authorized': authorized},
    );
  }
}

/// The conversation table has no description column, so a description lives
/// only in memory and is lost on the next database refresh; the assistant
/// must not claim to have changed it.
const _descriptionNotSaved = '角色简介目前不会保存（已知问题），暂时不能改；可以把要写的简介告诉用户';

/// A refused call; a [StateError] so tool groups that report state errors
/// report it too.
class _Invalid extends StateError {
  _Invalid(super.message);
}

class _RoleApplier extends CheckedChangeApplier {
  _RoleApplier(this.roles);

  final AssistantRoleStore roles;

  static Map<String, Object?> _fields(Map<String, Object?> state) => {
    for (final MapEntry(:key, :value) in state.entries)
      if (key != 'role_id') key: value,
  };

  @override
  Future<void> apply(Map<String, Object?> state) =>
      roles.edit(state['role_id']! as String, _fields(state));

  static bool _matches(Conversation role, Map<String, Object?> state) =>
      !role.isHidden &&
      _fields(state).entries.every(
        (field) => RoleField.same(RoleField.read(role, field.key), field.value),
      );

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final role = (await roles.load())
        .where((r) => r.id == state['role_id'])
        .firstOrNull;
    return role != null && _matches(role, state);
  }

  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) => roles.editIf(
    state['role_id']! as String,
    (role) => _matches(role, expected),
    _fields(state),
  );
}

class _RoleCreatedApplier extends CheckedChangeApplier {
  _RoleCreatedApplier(this.roles);

  final AssistantRoleStore roles;

  @override
  Future<void> apply(Map<String, Object?> state) async {
    if (state['exists'] == true) {
      throw StateError('新建的角色撤销后在回收站里，从回收站恢复');
    }
    await roles.delete(state['role_id']! as String);
  }

  static bool _untouched(Conversation role, Map<String, Object?> state) {
    final fields = state['fields'];
    final updatedAt = state['updated_at'];
    return !role.isHidden &&
        fields is Map &&
        updatedAt is int &&
        role.updatedAt.millisecondsSinceEpoch == updatedAt &&
        fields.entries.every(
          (field) => RoleField.same(
            RoleField.read(role, field.key as String),
            field.value,
          ),
        );
  }

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final role = (await roles.load())
        .where((r) => r.id == state['role_id'])
        .firstOrNull;
    if (state['exists'] != true) return role == null;
    return role != null && _untouched(role, state);
  }

  /// Only a card nobody has edited or chatted with goes to the trash.
  @override
  Future<bool> applyIfCurrent(
    Map<String, Object?> expected,
    Map<String, Object?> state,
  ) async {
    if (state['exists'] == true || expected['exists'] != true) {
      return super.applyIfCurrent(expected, state);
    }
    return roles.deleteIf(
      state['role_id']! as String,
      (role, messages) => messages == 0 && _untouched(role, expected),
    );
  }
}

class _PresetItemApplier extends CheckedChangeApplier {
  _PresetItemApplier(this.presets);

  final SillyTavernPresetStore presets;

  static bool? enabledOf(SillyTavernPreset preset, Map<String, Object?> item) {
    final id = item['item_id'];
    switch (item['kind']) {
      case 'prompt':
        return preset.selectedOrder.entries
            .where((e) => e.identifier == id)
            .firstOrNull
            ?.enabled;
      case 'regex':
        final script = preset.regexScripts.where((s) => s.id == id).firstOrNull;
        return script == null ? null : !script.disabled;
      case 'world_book':
        return preset.worldBooks.where((b) => b.id == id).firstOrNull?.enabled;
      case 'world_entry':
        return preset.worldBooks
            .where((b) => b.id == item['book_id'])
            .firstOrNull
            ?.entries
            .where((e) => e.id == id)
            .firstOrNull
            ?.enabled;
    }
    return null;
  }

  static String nameOf(SillyTavernPreset preset, Map<String, Object?> item) {
    final id = item['item_id'];
    final name = switch (item['kind']) {
      'prompt' => preset.promptsById[id]?.name,
      'regex' => preset.regexScripts.where((s) => s.id == id).firstOrNull?.name,
      'world_book' =>
        preset.worldBooks.where((b) => b.id == id).firstOrNull?.name,
      _ =>
        preset.worldBooks
            .where((b) => b.id == item['book_id'])
            .firstOrNull
            ?.entries
            .where((e) => e.id == id)
            .firstOrNull
            ?.name,
    };
    return (name == null || name.trim().isEmpty) ? '$id' : name;
  }

  @override
  Future<void> apply(Map<String, Object?> state) async {
    final presetId = state['preset_id']! as String;
    final id = state['item_id']! as String;
    final enabled = state['enabled'] == true;
    switch (state['kind']) {
      case 'prompt':
        await presets.setPromptEnabled(presetId, id, enabled);
      case 'regex':
        await presets.setRegexEnabled(presetId, id, enabled);
      case 'world_book':
        await presets.setWorldBookEnabled(presetId, id, enabled);
      case 'world_entry':
        await presets.setWorldEntryEnabled(
          presetId,
          state['book_id']! as String,
          id,
          enabled,
        );
      default:
        throw StateError('未知的预设条目类型：${state['kind']}');
    }
  }

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final preset = await presets.get(state['preset_id']! as String);
    return preset != null && enabledOf(preset, state) == state['enabled'];
  }
}

class _RegexAuthorizationApplier extends CheckedChangeApplier {
  _RegexAuthorizationApplier(this.presets);

  final SillyTavernPresetStore presets;

  @override
  Future<void> apply(Map<String, Object?> state) async {
    final ok = await presets.setRegexAuthorization(
      state['preset_id']! as String,
      state['authorized'] == true,
    );
    if (!ok) throw StateError('预设不存在或无法写入');
  }

  @override
  Future<bool> isCurrent(Map<String, Object?> state) async {
    final preset = await presets.get(state['preset_id']! as String);
    return preset != null && preset.regexAuthorized == state['authorized'];
  }
}
