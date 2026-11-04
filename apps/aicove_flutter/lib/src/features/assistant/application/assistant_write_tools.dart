import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ReversibleChange, ToolCallScope, ToolEffect;

import '../../agent_context/data/silly_tavern_preset_store.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_plugins/file_change_journal.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../chat/domain/role_agent_mode.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/time_awareness/time_awareness_role_options.dart';
import '../domain/assistant_onboarding.dart' show kAicoveAssistantId;
import 'assistant_review.dart';

/// Standard plugins; explicit extensions are loaded separately at call time.
const kAssistantRolePlugins = <String, String>{
  'memory': '记忆库',
  'trigger': '主动回复',
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
  Future<String> create({RoleAgentMode mode = RoleAgentMode.chat});

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
  static const extraPrompt = 'extra_prompt';
  static const customDrawingPrompt = 'custom_drawing_prompt';
  static const drawingPromptPackId = 'drawing_prompt_pack_id';
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
  static const agentMode = 'agent_mode';
  static const modelOverride = 'model_override';

  /// This chat's display style: `bubble`, `document`, or null to follow the
  /// default.
  static const displayStyle = 'display_style';

  /// Mask and blur of the chat's own wallpaper; null uses the default.
  static const wallpaperMask = 'wallpaper_mask';
  static const wallpaperBlur = 'wallpaper_blur';

  /// Per-chat view preferences; null follows the old global value.
  static const imagePreviewScale = 'image_preview_scale';
  static const expandAudioText = 'expand_audio_text';
  static const hideUserAvatar = 'hide_user_avatar';

  /// Per-chat bubble chunking; null follows the default.
  static const chunkEnabled = 'chunk_enabled';

  /// Per-chat fields that moved to global settings. Undo records made before
  /// that may still name them; they are skipped when undoing.
  static const retired = {'filter_punctuation', 'chunk_punctuation_set'};

  /// The role's drawing preset binding: `{id?, tool?, artist?}` (the last
  /// two are legacy bindings by name), null to follow the default preset.
  static const drawingPreset = 'drawing_preset';

  static const labels = {
    displayName: '名字',
    description: '简介',
    personaPrompt: '人设提示词',
    extraPrompt: '附加提示词',
    customDrawingPrompt: '自定义绘图提示',
    drawingPromptPackId: '生图提示词包',
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
    agentMode: '工作模式',
    modelOverride: '专属模型',
    displayStyle: '聊天样式',
    wallpaperMask: '聊天壁纸遮罩',
    wallpaperBlur: '聊天壁纸模糊',
    imagePreviewScale: '图片预览大小',
    expandAudioText: '语音消息默认展开文字',
    hideUserAvatar: '隐藏用户头像',
    chunkEnabled: '消息分段',
    drawingPreset: '绘图预设',
  };

  static Object? read(Conversation role, String key) {
    String? text(String? value) =>
        (value == null || value.trim().isEmpty) ? null : value;
    return switch (key) {
      displayName => role.displayName,
      description => text(role.description),
      personaPrompt =>
        role.id == kAicoveAssistantId
            ? PersonaPromptCodec.parse(role.personaPrompt).extraPrompt
            : PersonaPromptCodec.parse(role.personaPrompt).userPrompt,
      extraPrompt => PersonaPromptCodec.parse(role.personaPrompt).extraPrompt,
      drawingPromptPackId => text(
        PersonaPromptCodec.parse(role.personaPrompt).drawingPromptPackId,
      ),
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
      chatBackground =>
        text(role.chatBackgroundImage) == null
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
      // Keep the raw nullable mode so undo restores the original card.
      agentMode => role.agentMode?.name,
      modelOverride => role.sessionProvider,
      displayStyle => role.chatDisplayStyle?.name,
      wallpaperMask => role.chatBackgroundMaskOpacity,
      wallpaperBlur => role.chatBackgroundBlurSigma,
      imagePreviewScale => role.imagePreviewScale,
      expandAudioText => role.expandAudioText,
      hideUserAvatar => role.hideUserAvatar,
      chunkEnabled => role.chunkEnabled,
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
    this.extensionPlugins,
    this.extensionPluginNames,
  });

  final AssistantRoleStore roles;
  final SillyTavernPresetStore presets;
  final FileChangeJournal journal;

  /// Resolve after package/config initialization, on every write, not once
  /// when the request is assembled. No secrets or plugin code are read.
  final Future<Map<String, String>> Function()? extensionPlugins;
  final Map<String, String> Function()? extensionPluginNames;

  /// Called after every recorded change, so the undo list can refresh.
  final void Function()? onChanged;

  static const updateRole = 'aicove_update_role';
  static const createRole = 'aicove_create_role';
  static const setRolePlugins = 'aicove_set_role_plugins';
  static const bindPreset = 'aicove_bind_preset';
  static const togglePresetItem = 'aicove_toggle_preset_item';
  static const authorizeRegex = 'aicove_authorize_regex';

  static const roleTool = 'aicove_role';

  static String? roleToolName(Object? action) => switch (action) {
    'list' => 'aicove_list_roles',
    'read' => 'aicove_read_role',
    'create' => createRole,
    'update' => updateRole,
    _ => null,
  };

  static Map<String, dynamic> roleArguments(Map<String, dynamic> args) =>
      Map<String, dynamic>.of(args)..remove('action');

  AssistantRisk? riskOf(String toolName, Map<String, dynamic> args) =>
      toolName == roleTool
      ? switch (args['action']) {
          'list' || 'read' => AssistantRisk.readOnly,
          'create' || 'update' => riskOf(
            roleToolName(args['action'])!,
            roleArguments(args),
          ),
          _ => AssistantRisk.review,
        }
      : switch (toolName) {
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
    return added.any((id) => _externalPlugins.contains(id) || _isExtension(id))
        ? AssistantRisk.major
        : AssistantRisk.reversible;
  }

  /// What the user sees when a call needs their approval.
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    if (toolName == roleTool) {
      final atomic = roleToolName(args['action']);
      if (atomic == null) {
        return const ApprovalPrompt(title: '角色卡操作无效', detail: '请选择列出、读取、新建或修改');
      }
      return describe(atomic, roleArguments(args));
    }
    final role = _visible(roles.snapshot(), args['role_id']);
    final name = role == null ? '' : '「${role.displayName}」';
    String fields() => [
      for (final key in RoleField.labels.keys)
        if (args.containsKey(key) || args.containsKey('${key}_replace'))
          RoleField.labels[key]!,
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
        detail: _describePlugins(role, args),
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
      '局部修改使用对应的 _replace 对象（old_text/new_text），旧文本必须精确且仅出现一次；'
      '同一字段不能同时整体替换和局部修改。默认直接生效，用户可以撤销。',
      {
        'role_id': _string('aicove_list_roles 给出的角色 id'),
        RoleField.displayName: _string('名字'),
        RoleField.personaPrompt: _string(
          '完整的新人设提示词（整体替换，不是追加）；目标为 AIcove酱时只替换附加提示词，'
          '空字符串清空附加提示词，只读的 system_prompt 不可修改',
        ),
        'persona_prompt_replace': _replacementSchema,
        'extra_prompt_replace': _replacementSchema,
        'custom_drawing_prompt_replace': _replacementSchema,
        RoleField.extraPrompt: _string('附加提示词，空字符串清空'),
        RoleField.customDrawingPrompt: _string('角色长期生图提示词，空字符串清空'),
        RoleField.drawingPromptPackId: _string('角色生图提示词包 id，空字符串清空'),
        RoleField.selfAddress: _string('角色的自称'),
        RoleField.addressUser: _string('角色对用户的称呼'),
        RoleField.agentMode: _modeSchema,
        RoleField.modelOverride: _modelSchema,
      },
      ['role_id'],
      _updateRole,
    ),
    _tool(
      createRole,
      '新建一个角色卡，默认开启记忆库和时间感知；更多插件用 aicove_set_role_plugins 开启。'
      'agent_mode 默认 chat；tool 默认文档样式，chat 默认气泡样式。'
      '默认直接生效，用户可以撤销（撤销会把它移进回收站）。',
      {
        'name': _string('名字'),
        RoleField.personaPrompt: _string('人设提示词'),
        RoleField.extraPrompt: _string('附加提示词，空字符串清空'),
        RoleField.customDrawingPrompt: _string('角色长期生图提示词，空字符串清空'),
        RoleField.drawingPromptPackId: _string('角色生图提示词包 id，空字符串清空'),
        RoleField.selfAddress: _string('角色的自称'),
        RoleField.addressUser: _string('角色对用户的称呼'),
        RoleField.agentMode: _modeSchema,
        RoleField.modelOverride: _modelSchema,
      },
      ['name', RoleField.personaPrompt],
      _createRole,
    ),
    _tool(
      setRolePlugins,
      '设置角色插件，下一次 run 生效。all=true 只开启全部内置插件；否则 plugins 替换内置插件选择'
      '（${[for (final e in kAssistantRolePlugins.entries) '${e.key}=${e.value}'].join('，')}）。'
      '先用 aicove_list_available_plugins 查已安装 pkg: 与已配置 mcp:。'
      'plugins 含 pkg:/mcp: 时也替换扩展选择；只含内置插件时保留已有扩展。'
      'all=true 且传 plugins 时，扩展选择按 plugins 替换，不自动全开扩展。'
      '可单独传 extensions 完整替换扩展列表，[] 关闭全部扩展；不可与 plugins 中的扩展混用。'
      '未传 all/plugins 时保留内置选择。可单独传 current_time，只影响这个角色。'
      '空间授权和其他不可管理插件始终保留。',
      {
        'role_id': _string('角色 id'),
        'all': {'type': 'boolean', 'description': '是否开启全部内置插件，不自动开启扩展'},
        'current_time': {
          'type': 'boolean',
          'description': '是否让模型知道现在几点，只影响这个角色',
        },
        'plugins': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '内置插件及可选的 pkg:/mcp: id；扩展选择的替换规则见工具说明',
        },
        'extensions': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要开启的完整 pkg:/mcp: 列表；[] 关闭全部扩展，不传则按 plugins 规则处理',
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

  static const _modeSchema = {
    'type': 'string',
    'enum': ['chat', 'tool', 'agent'],
    'description':
        '工作模式：chat 聊天（不带工具）／tool 工具（单层 Agent）／agent 智能体（前台路由＋后台子 Agent）',
  };
  static const _modelSchema = {
    'type': 'string',
    'description':
        '专属模型 providerId:modelId，可用 aicove_list_providers 查看；空字符串清空并跟随默认模型',
  };

  String _describePlugins(Conversation? role, Map<String, dynamic> args) {
    final names = {...kAssistantRolePlugins, ...?extensionPluginNames?.call()};
    final selected = role == null
        ? {..._ids(args['plugins']), ..._ids(args['extensions'])}
        : _effectivePlugins(_requestedPlugins(role, args));
    final pluginNames = [
      for (final id in selected)
        if (!TimeAwarenessRoleOptions.isOptionId(id)) names[id] ?? id,
    ];
    return [
      '开启：${pluginNames.join('、')}',
      if (args['current_time'] case final bool currentTime)
        '现在几点：${currentTime ? '告诉' : '不告诉'}',
      if (selected.contains('web_search')) '联网搜索会把聊天内容用于搜索请求',
      if (selected.any(_isExtension)) '扩展包和 MCP 连接器将获得该角色的扩展能力，下一次 run 生效',
    ].join('\n');
  }

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
    String? changeDescription,
  }) async {
    final changed = {
      for (final MapEntry(:key, :value) in fields.entries)
        if (!RoleField.same(RoleField.read(role, key), value)) key: value,
    };
    if (changed.isEmpty) return {'ok': true, 'change': '没有变化'};
    final labels = [for (final key in changed.keys) RoleField.labels[key]!];
    final description =
        changeDescription ?? '改了「${role.displayName}」的${labels.join('、')}';
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

  void _validatePersonaFields(Map<String, dynamic> args) {
    for (final key in const [
      RoleField.extraPrompt,
      RoleField.customDrawingPrompt,
      RoleField.drawingPromptPackId,
    ]) {
      final value = args[key];
      if (value is String && PersonaPromptCodec.stripMarkers(value) != value) {
        throw _Invalid('${RoleField.labels[key]}包含冲突的内部标记，请移除标记后重试');
      }
    }
  }

  static const _replacementSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'old_text': {'type': 'string', 'description': '原文中精确且只出现一次的非空文本'},
      'new_text': {'type': 'string', 'description': '替换后的文本，可为空以删除片段'},
    },
    'required': ['old_text', 'new_text'],
    'additionalProperties': false,
  };

  Future<Map<String, Object?>> _updateRole(Map<String, dynamic> args) async {
    final role = await _role(args);
    args = Map<String, dynamic>.of(args);
    const replaceable = [
      RoleField.personaPrompt,
      RoleField.extraPrompt,
      RoleField.customDrawingPrompt,
    ];
    final replacing = replaceable.any(
      (key) => args.containsKey('${key}_replace'),
    );
    if (role.id == kAicoveAssistantId &&
        [RoleField.personaPrompt, RoleField.extraPrompt]
                .where(
                  (key) =>
                      args.containsKey(key) ||
                      args.containsKey('${key}_replace'),
                )
                .length >
            1) {
      throw _Invalid('persona_prompt 与 extra_prompt 都指向附加提示词，请只传一个');
    }
    for (final key in replaceable) {
      final replaceKey = '${key}_replace';
      if (!args.containsKey(replaceKey)) continue;
      if (args.containsKey(key)) throw _Invalid('$key 与 $replaceKey 不能同时提供');
      final patch = args[replaceKey];
      if (patch is! Map ||
          patch.length != 2 ||
          patch['old_text'] is! String ||
          patch['new_text'] is! String) {
        throw _Invalid('$replaceKey 需要 old_text 和 new_text 两个文本字段');
      }
      final oldText = patch['old_text'] as String;
      if (oldText.isEmpty) throw _Invalid('$replaceKey 的 old_text 不能为空');
      final original = RoleField.read(role, key) as String? ?? '';
      final index = original.indexOf(oldText);
      if (index < 0 || original.indexOf(oldText, index + 1) >= 0) {
        throw _Invalid('$replaceKey 的 old_text 必须在原文中精确出现一次，请重新读取角色');
      }
      args[key] = original.replaceRange(
        index,
        index + oldText.length,
        patch['new_text'] as String,
      );
      if (PersonaPromptCodec.stripMarkers(args[key] as String) != args[key]) {
        throw _Invalid('${RoleField.labels[key]}包含冲突的内部标记，请移除标记后重试');
      }
    }
    if (args.containsKey(RoleField.description)) {
      throw _Invalid(_descriptionNotSaved);
    }
    for (final key in RoleField.labels.keys) {
      if (args.containsKey(key) && args[key] is! String) {
        throw _Invalid('${RoleField.labels[key]}应为文本');
      }
    }
    _validatePersonaFields(args);
    if (role.id == kAicoveAssistantId &&
        args.containsKey(RoleField.personaPrompt) &&
        args.containsKey(RoleField.extraPrompt)) {
      throw _Invalid('persona_prompt 与 extra_prompt 都指向附加提示词，请只传一个');
    }
    final fields = <String, Object?>{};
    for (final key in const [
      RoleField.extraPrompt,
      RoleField.customDrawingPrompt,
      RoleField.drawingPromptPackId,
    ]) {
      if (args.containsKey(key)) {
        fields[key] = key == RoleField.extraPrompt
            ? (args[key] as String).trim()
            : _optionalText(args[key]);
      }
    }
    for (final key in const [RoleField.selfAddress, RoleField.addressUser]) {
      if (args.containsKey(key)) fields[key] = _optionalText(args[key]);
    }
    for (final key in const [RoleField.displayName, RoleField.personaPrompt]) {
      if (!args.containsKey(key)) continue;
      if (key == RoleField.personaPrompt && role.id == kAicoveAssistantId) {
        final extra = _optionalText(args[key]) ?? '';
        final encoded = PersonaPromptCodec.parse(
          PersonaPromptCodec.compose(userPrompt: '', extraPrompt: extra),
        );
        if (encoded.extraPrompt != extra || encoded.userPrompt.isNotEmpty) {
          throw _Invalid('附加提示词包含冲突的内部标记，请移除标记后重试');
        }
        fields[key] = extra;
        continue;
      }
      fields[key] =
          _optionalText(args[key]) ??
          (throw _Invalid('${RoleField.labels[key]}不能为空'));
    }
    fields.addAll(_modeAndModel(args, roleId: role.id));
    if (fields.isEmpty) throw _Invalid('没有要改的字段');
    return _editRole(
      updateRole,
      role,
      fields,
      guard: replacing
          ? (current) => fields.keys.every(
              (key) => RoleField.same(
                RoleField.read(current, key),
                RoleField.read(role, key),
              ),
            )
          : null,
    );
  }

  Future<Map<String, Object?>> _createRole(Map<String, dynamic> args) async {
    // Check every field before anything is created.
    for (final key in const [
      'name',
      RoleField.personaPrompt,
      RoleField.extraPrompt,
      RoleField.customDrawingPrompt,
      RoleField.drawingPromptPackId,
      RoleField.selfAddress,
      RoleField.addressUser,
    ]) {
      final value = args[key];
      if (value != null && value is! String) {
        throw _Invalid('${RoleField.labels[key] ?? '名字'}应为文本');
      }
    }
    _validatePersonaFields(args);
    final name = _optionalText(args['name']) ?? (throw _Invalid('名字不能为空'));
    final prompt =
        _optionalText(args[RoleField.personaPrompt]) ??
        (throw _Invalid('人设提示词不能为空'));
    final options = _modeAndModel(args);
    final mode =
        RoleAgentMode.fromValue(options[RoleField.agentMode] as String?) ??
        RoleAgentMode.chat;
    final id = await roles.create(mode: mode);
    await roles.edit(id, {
      RoleField.displayName: name,
      RoleField.personaPrompt: prompt,
      if (args.containsKey(RoleField.extraPrompt))
        RoleField.extraPrompt: (args[RoleField.extraPrompt] as String).trim(),
      if (args.containsKey(RoleField.customDrawingPrompt))
        RoleField.customDrawingPrompt: _optionalText(
          args[RoleField.customDrawingPrompt],
        ),
      if (args.containsKey(RoleField.drawingPromptPackId))
        RoleField.drawingPromptPackId: _optionalText(
          args[RoleField.drawingPromptPackId],
        ),
      RoleField.selfAddress: _optionalText(args[RoleField.selfAddress]),
      RoleField.addressUser: _optionalText(args[RoleField.addressUser]),
      // New roles start with the default plugins, as on the role edit page.
      RoleField.enabledPlugins: kDefaultRolePluginIds,
      ...options,
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

  static Map<String, Object?> _modeAndModel(
    Map<String, dynamic> args, {
    String? roleId,
  }) {
    final fields = <String, Object?>{};
    if (args.containsKey(RoleField.agentMode)) {
      final mode = args[RoleField.agentMode];
      if (mode != 'chat' && mode != 'tool' && mode != 'agent') {
        throw _Invalid('agent_mode 应为 chat、tool 或 agent');
      }
      if (roleId == kAicoveAssistantId && mode != 'tool') {
        throw _Invalid('AIcove酱恒为 tool 模式，不能改为 $mode');
      }
      fields[RoleField.agentMode] = mode;
    }
    if (args.containsKey(RoleField.modelOverride)) {
      final value = args[RoleField.modelOverride];
      if (value is! String) throw _Invalid('model_override 应为文本');
      final model = _optionalText(value);
      if (model != null) {
        // Model ids may themselves contain colons. Split at the first one.
        final colon = model.indexOf(':');
        if (colon <= 0 || model.substring(colon + 1).trim().isEmpty) {
          throw _Invalid('model_override 应为 providerId:modelId，空字符串恢复默认');
        }
      }
      fields[RoleField.modelOverride] = model;
    }
    return fields;
  }

  static List<String> _ids(Object? value) => [
    if (value is List)
      for (final id in value) id.toString().trim(),
  ];

  static bool _isExtension(String id) =>
      id.startsWith('pkg:') || id.startsWith('mcp:');

  static Set<String> _effectivePlugins(List<String>? enabled) =>
      enabled == null ? kAssistantRolePlugins.keys.toSet() : enabled.toSet();

  /// Legacy standard-only calls retain extensions; explicit lists replace
  /// them. Unmanaged ids (notably workspace grants) always survive.
  static List<String>? _requestedPlugins(
    Conversation role,
    Map<String, dynamic> args,
  ) {
    final wanted = _ids(args['plugins']).toSet();
    final before = _effectivePlugins(role.enabledPlugins);
    final replaceExtensions =
        args.containsKey('extensions') ||
        wanted.any(_isExtension) ||
        (args['all'] == true && args.containsKey('plugins'));
    final extensions = args.containsKey('extensions')
        ? _ids(args['extensions'])
        : replaceExtensions
        ? wanted.where(_isExtension)
        : before.where(_isExtension);
    final standard = args['all'] == true
        ? kAssistantRolePlugins.keys
        : (args.containsKey('plugins') ? wanted : before).where(
            kAssistantRolePlugins.containsKey,
          );
    var result = <String>{
      ...standard,
      ...extensions,
      ...before.where(
        (id) => !kAssistantRolePlugins.containsKey(id) && !_isExtension(id),
      ),
    };
    if (args['current_time'] case final bool currentTime) {
      result = TimeAwarenessRoleOptions.withCurrentTime(result, currentTime);
    }
    // Preserve the edit page's null representation for all standard plugins.
    return args['all'] == true && result.length == kAssistantRolePlugins.length
        ? null
        : result.toList();
  }

  Future<Map<String, Object?>> _setRolePlugins(
    Map<String, dynamic> args,
  ) async {
    final role = await _role(args);
    if (args.containsKey('all') && args['all'] is! bool) {
      throw _Invalid('all 应为 true 或 false');
    }
    if (args.containsKey('current_time') && args['current_time'] is! bool) {
      throw _Invalid('current_time 应为 true 或 false');
    }
    if (args['all'] != true &&
        !args.containsKey('plugins') &&
        !args.containsKey('extensions') &&
        !args.containsKey('current_time')) {
      throw _Invalid('请传 plugins、extensions、current_time 或 all=true');
    }
    for (final key in ['plugins', 'extensions']) {
      if (!args.containsKey(key)) continue;
      final ids = args[key];
      if (ids is! List || ids.any((id) => id is! String)) {
        throw _Invalid('$key 应为插件 id 的列表');
      }
    }
    if (args.containsKey('extensions') &&
        _ids(args['plugins']).any(_isExtension)) {
      throw _Invalid('extensions 不可与 plugins 中的 pkg:/mcp: 混用');
    }
    final known = {
      ...kAssistantRolePlugins,
      ...?await extensionPlugins?.call(),
    };
    final unknown = {
      for (final id in _ids(args['plugins']))
        if (!known.containsKey(id)) id,
      for (final id in _ids(args['extensions']))
        if (!_isExtension(id) || !known.containsKey(id)) id,
    };
    if (unknown.isNotEmpty) {
      throw _Invalid(
        '不认识或未安装/配置的插件 id：${unknown.join('、')}；'
        '可用：${known.entries.map((e) => '${e.key}=${e.value}').join('、')}',
      );
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
        approvedMajor ||
        _pluginRiskFor(current, args) != AssistantRisk.major;
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
      changeDescription:
          '改了「${role.displayName}」的插件\n${_describePlugins(role, args)}',
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
      if (key != 'role_id' && !RoleField.retired.contains(key)) key: value,
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
          (field) =>
              RoleField.retired.contains(field.key) ||
              RoleField.same(
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
