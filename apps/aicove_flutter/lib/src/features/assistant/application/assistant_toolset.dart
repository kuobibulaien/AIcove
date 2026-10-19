import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;

import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../chat/domain/chat_context_preview.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../domain/aicove_docs.dart';

/// Read-only tools of the AIcove assistant (ADR0073, batch T2): the docs
/// library, roles, tavern presets and a role's assembled request context.
/// Writes live in [AssistantWriteTools].
///
/// Roles moved into the privacy space never show up. Chat text and memories
/// stay out: the context inspection reports sizes only, because assembled
/// sources mix them in (preset macros such as {{lastUserMessage}}, memories
/// inside the runtime block); role and preset text is read unexpanded with
/// their own tools.
class AssistantToolset {
  AssistantToolset({
    required this.roles,
    required this.presets,
    required this.previewContext,
    required this.readDoc,
  });

  final Future<List<Conversation>> Function() roles;
  final Future<List<SillyTavernPreset>> Function() presets;
  final Future<ChatContextPreview> Function(Conversation role) previewContext;
  final Future<String?> Function(String docId) readDoc;

  static const _promptContentLimit = 1500;

  List<AITool> tools() => [
    _tool(
      'aicove_docs_read',
      '读取 AIcove 内置资料库中的一篇文档（文档列表见系统提示词）。',
      {
        'doc': {'type': 'string', 'description': '文档 id'},
      },
      ['doc'],
      ToolEffect.readDiagnostic,
      _readDoc,
    ),
    _tool(
      'aicove_list_roles',
      '列出用户的角色（不含隐私空间里的）：名字、简介、插件选择、绑定的酒馆预设。',
      const {},
      const [],
      ToolEffect.readPrivate,
      _listRoles,
    ),
    _tool(
      'aicove_read_role',
      '读取一个角色卡的完整设定：人设提示词、自定义绘图提示、称呼、插件选择、预设、思考档位等。',
      {
        'role_id': {
          'type': 'string',
          'description': 'aicove_list_roles 给出的角色 id',
        },
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _readRole,
    ),
    _tool(
      'aicove_list_presets',
      '列出已导入的酒馆预设：启用条目数、正则、世界书、函数调用开关、告警，以及哪些角色绑定了它。',
      const {},
      const [],
      ToolEffect.readPrivate,
      _listPresets,
    ),
    _tool(
      'aicove_read_preset',
      '读取一个酒馆预设：按当前顺序列出提示词条目（含是否启用、注入位置与内容）、正则脚本、世界书条目和参数兼容情况。',
      {
        'preset_id': {
          'type': 'string',
          'description': 'aicove_list_presets 给出的预设 id',
        },
      },
      ['preset_id'],
      ToolEffect.readPrivate,
      _readPreset,
    ),
    _tool(
      'aicove_inspect_context',
      '按真实发送的装配流程，预览某个角色下一次请求的上下文：模型、预设、各插件是否注入及原因、'
          '系统提示词各来源的大小、工具列表、token 用量与压缩阈值。排查「插件没生效」「回复不对劲」「上下文太长」时用。'
          '只给结构和大小，不给任何正文；要看人设或预设原文，用 aicove_read_role／aicove_read_preset。',
      {
        'role_id': {'type': 'string', 'description': '角色 id'},
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _inspectContext,
    ),
  ];

  AITool _tool(
    String name,
    String description,
    Map<String, Object> properties,
    List<String> required,
    ToolEffect effect,
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
    effect: effect,
    handler: (args) async {
      try {
        return jsonEncode(await run(args));
      } on _NotFound catch (error) {
        return jsonEncode({'error': 'not_found', 'message': error.message});
      }
    },
  );

  Future<List<Conversation>> _visibleRoles() async => [
    for (final role in await roles())
      if (!role.isHidden) role,
  ];

  Future<Conversation> _role(Map<String, dynamic> args) async {
    final id = (args['role_id'] ?? '').toString().trim();
    for (final role in await _visibleRoles()) {
      if (role.id == id) return role;
    }
    throw _NotFound('没有 id 为「$id」的角色');
  }

  Future<Map<String, String>> _presetNames() async => {
    for (final preset in await presets()) preset.id: preset.name,
  };

  static String _clip(String text, int limit) => text.length <= limit
      ? text
      : '${text.substring(0, limit)}…（共 ${text.length} 字，已截断）';

  static Object _pluginSelection(Conversation role) =>
      switch (role.enabledPlugins) {
        null => '全部插件',
        final ids when ids.isEmpty => '一个都没开',
        final ids => ids,
      };

  Map<String, Object?> _roleSummary(
    Conversation role,
    Map<String, String> presetNames,
  ) => {
    'id': role.id,
    'name': role.displayName,
    if ((role.description ?? '').isNotEmpty)
      'description': _clip(role.description!, 80),
    'plugins': _pluginSelection(role),
    'preset': role.recipeId == null
        ? null
        : presetNames[role.recipeId] ?? '已绑定但本机找不到（${role.recipeId}）',
    'pinned': role.isPinned,
  };

  Future<Map<String, Object?>> _listRoles(Map<String, dynamic> _) async {
    final presetNames = await _presetNames();
    return {
      'roles': [
        for (final role in await _visibleRoles())
          _roleSummary(role, presetNames),
      ],
    };
  }

  Future<Map<String, Object?>> _readDoc(Map<String, dynamic> args) async {
    final id = (args['doc'] ?? '').toString().trim();
    final content = await readDoc(id);
    if (content == null) {
      throw _NotFound(
        '没有这篇文档，可用：${[for (final doc in kAicoveDocs) doc.id].join('、')}',
      );
    }
    return {'doc': id, 'content': content};
  }

  Future<Map<String, Object?>> _readRole(Map<String, dynamic> args) async {
    final role = await _role(args);
    final parts = PersonaPromptCodec.parse(role.personaPrompt);
    final presetNames = await _presetNames();
    return {
      ..._roleSummary(role, presetNames),
      'description': role.description,
      'persona_prompt': parts.userPrompt,
      if (parts.customDrawingPrompt.isNotEmpty)
        'custom_drawing_prompt': parts.customDrawingPrompt,
      if (role.selfAddress != null) 'self_address': role.selfAddress,
      if (role.addressUser != null) 'address_user': role.addressUser,
      if (role.voiceFile != null) 'voice_preset': role.voiceFile,
      if (role.thinkingLevels.isNotEmpty)
        'thinking_levels': {
          for (final entry in role.thinkingLevels.entries)
            entry.key: entry.value.name,
        },
      if (role.sessionProvider != null) 'model_override': role.sessionProvider,
      'has_avatar': (role.avatarUrl ?? role.characterImage) != null,
    };
  }

  Future<Map<String, Object?>> _listPresets(Map<String, dynamic> _) async {
    final visible = await _visibleRoles();
    return {
      'presets': [
        for (final preset in await presets())
          {
            'id': preset.id,
            'name': preset.name,
            'enabled_prompts': preset.enabledPromptCount,
            'total_prompts': preset.prompts.length,
            'regex_scripts': preset.regexScripts.length,
            'regex_authorized': preset.regexAuthorized,
            'world_books': [
              for (final book in preset.worldBooks)
                {
                  'name': book.name,
                  'enabled': book.enabled,
                  'entries': book.entries.length,
                },
            ],
            'function_calling': preset.functionCalling,
            'warnings': preset.warnings.length,
            'used_by_roles': [
              for (final role in visible)
                if (role.recipeId == preset.id) role.displayName,
            ],
          },
      ],
    };
  }

  Future<Map<String, Object?>> _readPreset(Map<String, dynamic> args) async {
    final id = (args['preset_id'] ?? '').toString().trim();
    final preset = (await presets()).where((p) => p.id == id).firstOrNull;
    if (preset == null) throw _NotFound('没有 id 为「$id」的预设');
    final byId = preset.promptsById;
    return {
      'id': preset.id,
      'name': preset.name,
      'prompt_order': [
        for (final entry in preset.selectedOrder.entries)
          if (byId[entry.identifier] case final prompt?)
            {
              'identifier': prompt.identifier,
              'name': prompt.name,
              'enabled': entry.enabled,
              'role': prompt.role,
              if (prompt.marker) 'marker': true,
              if (prompt.injectionPosition != 0) ...{
                'injection_position': prompt.injectionPosition,
                'injection_depth': prompt.injectionDepth,
              },
              if (!prompt.marker)
                'content': _clip(prompt.content, _promptContentLimit),
            },
      ],
      'regex_scripts': [
        for (final script in preset.regexScripts)
          {
            'id': script.id,
            'name': script.name,
            'disabled': script.disabled,
            'placements': script.placements,
            if (script.promptOnly) 'prompt_only': true,
            if (script.markdownOnly) 'display_only': true,
          },
      ],
      'regex_authorized': preset.regexAuthorized,
      'world_books': [
        for (final book in preset.worldBooks)
          {
            'id': book.id,
            'name': book.name,
            'enabled': book.enabled,
            'entries': [
              for (final entry in book.entries)
                {
                  'id': entry.id,
                  'name': entry.name,
                  'enabled': entry.enabled,
                  if (entry.constant) 'constant': true,
                  'keys': entry.keys,
                },
            ],
          },
      ],
      'function_calling': preset.functionCalling,
      'parameter_compatibility': [
        for (final item in preset.parameterCompatibility)
          {
            'field': item.field,
            'status': item.status.name,
            'reason': item.reason,
          },
      ],
      if (preset.warnings.isNotEmpty) 'warnings': preset.warnings,
    };
  }

  Future<Map<String, Object?>> _inspectContext(
    Map<String, dynamic> args,
  ) async {
    final role = await _role(args);
    final preview = await previewContext(role);
    final roleCounts = <String, int>{};
    final roleTokens = <String, int>{};
    for (final (index, message) in preview.messages.indexed) {
      final kind = (message['role'] ?? 'unknown').toString();
      roleCounts[kind] = (roleCounts[kind] ?? 0) + 1;
      roleTokens[kind] =
          (roleTokens[kind] ?? 0) +
          (index < preview.messageTokens.length
              ? preview.messageTokens[index]
              : 0);
    }
    return {
      'role': role.displayName,
      'model': preview.modelId,
      'preset': preview.presetName,
      'input_tokens': preview.inputTokens,
      'compaction_threshold': preview.inputLimit,
      'plugins': [
        for (final plugin in preview.plugins)
          {
            'name': plugin.name,
            'injected': plugin.injected,
            // Exception text is free-form and may quote request content.
            if (plugin.failed)
              'reason': '插件提示词构建出错，详情见「设置 · 调试 · 联系人上下文」'
            else if (plugin.reason != null)
              'reason': plugin.reason,
          },
      ],
      'system_sources': [
        for (final source in preview.sources)
          {'label': source.label, 'chars': source.content.length},
      ],
      'tools': [
        for (final tool in preview.tools)
          ((tool['function'] as Map?)?['name'] ?? tool['name']).toString(),
      ],
      'messages': {
        for (final kind in roleCounts.keys)
          kind: {'count': roleCounts[kind], 'tokens': roleTokens[kind]},
      },
      // Assembly warnings quote expanded macros and so may carry chat text;
      // report how many there are, never their wording.
      'warning_count': preview.notes.length,
    };
  }
}

class _NotFound implements Exception {
  const _NotFound(this.message);
  final String message;
}
