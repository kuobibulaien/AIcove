import 'dart:convert';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope, ToolEffect, ReversibleChange;
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../agent_plugins/file_change_journal.dart';
import '../../memory/domain/memory_item.dart';
import '../../context/domain/context_summary.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/handlers/tool_schema_validator.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

/// One chat message as the assistant reads it.
typedef AssistantChatLine = ({String role, String content, DateTime at});

/// One long-term memory as the assistant reads it.
typedef AssistantMemoryLine = ({String title, String content, bool locked});

const assistantPrivateDataChangeKind = 'assistant.private_data';

bool sameAssistantPrivateState(
  Map<String, Object?> a,
  Map<String, Object?> b,
) => jsonEncode(a) == jsonEncode(b);

/// The adapter checks ownership, privacy and the exact stored state again in
/// the same transaction as the write. Journal undo uses this same path.
abstract class AssistantPrivateDataChanges extends CheckedChangeApplier {
  Future<Map<String, Object?>?> summary(
    String ownerId,
    ContextSummaryKind kind,
  );
  Future<Map<String, Object?>?> memory(String ownerId, String id);

  @override
  Future<void> apply(Map<String, Object?> state) =>
      Future.error(StateError('私有内容必须按原版本核对后才能保存'));
}

/// Roles whose chat and memory the user let the assistant read, kept on
/// this device only (ADR0073 full access: one approval per role).
class AssistantReadGrants {
  AssistantReadGrants({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  static const prefsKey = 'assistant_read_grants_v1';

  final Future<SharedPreferences> Function() _prefs;
  Set<String>? _granted;

  /// Known grants without waiting; empty until [load] has run once.
  Set<String> get current => _granted ?? const {};

  Future<Set<String>> load() async {
    final stored = (await _prefs()).getStringList(prefsKey);
    return _granted ??= {...?stored};
  }

  Future<void> grant(String roleId) =>
      _serial(() async => _save({...await load(), roleId}));

  Future<void> revoke(String roleId) =>
      _serial(() async => _save({...await load()}..remove(roleId)));

  /// Grants and revokes run one after another, so a late write never puts
  /// back a grant that was revoked meanwhile.
  Future<void> _last = Future.value();

  Future<void> _serial(Future<void> Function() body) {
    final result = _last.then((_) => body());
    _last = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _save(Set<String> ids) async {
    _granted = ids;
    await (await _prefs()).setStringList(prefsKey, ids.toList()..sort());
  }
}

/// Reading another role's chat and memory (ADR0073 full access, batch P5).
/// Default assistant runs read directly. In manual mode, the first approval
/// grants later reads of that role. Privacy-space roles remain inaccessible.
class AssistantPrivateReadTools extends AssistantToolGroup {
  AssistantPrivateReadTools({
    required this.roles,
    required this.rolesNow,
    required this.grants,
    required this.messages,
    required this.memories,
    this.rawMessages,
    this.memoryItems,
    this.readBoundary,
    this.summaryHistory,
    this.changes,
    this.journal,
    this.onChanged,
    this.writePrivate,
  });

  /// Visible roles only.
  final Future<List<Conversation>> Function() roles;

  /// The role list without waiting, for naming the role on the approval card.
  final List<Conversation> Function() rolesNow;
  final AssistantReadGrants grants;
  final Future<List<AssistantChatLine>> Function(
    String roleId, {
    required int limit,
    DateTime? before,
    String? keyword,
  })
  messages;
  final Future<List<AssistantMemoryLine>> Function(String roleId) memories;
  final Future<List<Message>> Function(String roleId)? rawMessages;
  final Future<List<MemoryItem>> Function(String roleId)? memoryItems;
  final Future<String?> Function(String roleId)? readBoundary;
  final Future<List<ContextSummaryHistoryEntry>> Function(String roleId)?
  summaryHistory;
  final AssistantPrivateDataChanges? changes;
  final FileChangeJournal? journal;
  final void Function()? onChanged;
  final Future<Map<String, Object?>> Function(
    String tool,
    Map<String, dynamic> args,
  )?
  writePrivate;

  static const readChat = 'aicove_read_role_chat';
  static const readMemory = 'aicove_read_role_memory';
  static const readSummary = 'aicove_read_role_summary';
  static const revoke = 'aicove_revoke_read';
  static const editSummary = 'aicove_write_role_summary';
  static const appendChat = 'aicove_append_role_chat';
  static const updateChat = 'aicove_update_role_chat';
  static const deleteChat = 'aicove_delete_role_chat';
  static const deleteSummary = 'aicove_delete_role_summary';
  static const writeMemory = 'aicove_write_role_memory';
  static const deleteMemory = 'aicove_delete_role_memory';
  static const _writes = {
    editSummary,
    appendChat,
    updateChat,
    deleteChat,
    deleteSummary,
    writeMemory,
    deleteMemory,
  };

  static const _maxLines = 100;
  static const _maxChars = 1500;

  static const _roleId = {
    'type': 'string',
    'description': 'aicove_list_roles 给出的角色 id',
  };

  List<AITool> _atomicTools() => [
    assistantTool(
      readChat,
      '读某个角色的聊天记录（从新到旧，最多 $_maxLines 条）。默认无需逐次审批；开启「修改前每次问我」时，第一次读一个角色要用户同意，'
      '同意后这个角色以后可以直接读。只在排查需要时读，读到的内容别复述给用户以外的地方。',
      {
        'role_id': _roleId,
        'limit': {'type': 'integer', 'description': '条数，默认 30'},
        'before': {
          'type': 'string',
          'description': '只读这个时间之前的（ISO 时间，翻页用上次最早一条的时间）',
        },
        'keyword': {'type': 'string', 'description': '只找包含这个词的消息'},
        'before_message_id': {'type': 'string', 'description': '只读此消息之前的记录'},
        'after_message_id': {'type': 'string', 'description': '只读此消息之后的记录'},
        'message_id': {'type': 'string', 'description': '读取指定消息全文'},
        'active_topic_only': {'type': 'boolean', 'description': '只读当前话题'},
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _readChat,
    ),
    assistantTool(
      readMemory,
      '读某个角色的长期记忆（记忆 Agent 整理的和用户锁定的）。授权规则同 $readChat。',
      {
        'role_id': _roleId,
        'layer': {
          'type': 'string',
          'enum': ['core', 'archive'],
        },
        'keyword': {'type': 'string'},
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _readMemory,
    ),
    assistantTool(
      readSummary,
      '读取角色当前话题摘要，可选查看历史摘要。',
      {
        'role_id': _roleId,
        'include_history': {'type': 'boolean'},
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _readSummary,
    ),
    assistantTool(
      editSummary,
      '修改角色当前有效摘要的正文，保留来源和话题边界，可撤销。可选传回读取时的 summary_id 和 expected_summary；'
      '不传时修改执行当下的有效摘要。mode=compact_current_topic 将当前话题整理为新摘要并开启新话题，不支持助手撤销。'
      '省略 mode 且有 kind 时按 update_current 处理。',
      {
        'role_id': _roleId,
        'mode': {
          'type': 'string',
          'enum': ['update_current', 'compact_current_topic'],
        },
        'kind': {
          'type': 'string',
          'enum': ['manual', 'auto'],
        },
        'summary_id': {'type': 'string'},
        'expected_summary': {'type': 'string'},
        'summary': {'type': 'string'},
        'expected_revision': {'type': 'string'},
      },
      ['role_id', 'summary'],
      ToolEffect.write,
      _editSummary,
    ),
    assistantTool(
      appendChat,
      '向角色聊天追加一条原文，sender_role 默认 assistant；正文去掉首尾空白，不触发回复，不支持助手撤销。',
      {
        'role_id': _roleId,
        'sender_role': {
          'type': 'string',
          'enum': ['user', 'assistant'],
          'default': 'assistant',
        },
        'content': {'type': 'string'},
      },
      ['role_id', 'content'],
      ToolEffect.write,
      (args) => _write(appendChat, args),
    ),
    assistantTool(
      updateChat,
      '修改指定聊天原文。传 content 整段替换，或 content_replace={old_text,new_text} 精确替换唯一一处，两种方式不能同时使用；复杂消息会拒绝，不支持助手撤销。',
      {
        'role_id': _roleId,
        'message_id': {'type': 'string'},
        'content': {'type': 'string'},
        'content_replace': {
          'type': 'object',
          'properties': {
            'old_text': {'type': 'string', 'minLength': 1},
            'new_text': {'type': 'string'},
          },
          'required': ['old_text', 'new_text'],
          'additionalProperties': false,
        },
        'old_text': {'type': 'string'},
        'new_text': {'type': 'string'},
      },
      ['role_id', 'message_id'],
      ToolEffect.write,
      (args) => _write(updateChat, args),
    ),
    assistantTool(
      deleteChat,
      '删除角色的一批聊天原文；任一目标无效则整批不删除，不支持助手撤销。',
      {
        'role_id': _roleId,
        'message_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      ['role_id', 'message_ids'],
      ToolEffect.write,
      (args) => _write(deleteChat, args),
    ),
    assistantTool(
      deleteSummary,
      '删除当前摘要。manual 撤销上次话题压缩并恢复上次边界；auto 仅删除当前话题自动摘要。不支持助手撤销此操作。',
      {
        'role_id': _roleId,
        'kind': {
          'type': 'string',
          'enum': ['manual', 'auto'],
        },
      },
      ['role_id', 'kind'],
      ToolEffect.write,
      (args) => _write(deleteSummary, args),
    ),
    assistantTool(
      writeMemory,
      '新增或修改角色长期记忆；给 memory_id 修改已有条目，不给则新增。保存后默认锁定，可显式 locked=false 解锁；不支持助手撤销。',
      {
        'role_id': _roleId,
        'memory_id': {'type': 'string'},
        'layer': {
          'type': 'string',
          'enum': ['core', 'archive'],
        },
        'title': {'type': 'string'},
        'content': {'type': 'string'},
        'locked': {'type': 'boolean'},
      },
      ['role_id', 'layer', 'title', 'content'],
      ToolEffect.write,
      (args) => _write(writeMemory, args),
    ),
    assistantTool(
      deleteMemory,
      '删除角色的一条长期记忆，不支持助手撤销。',
      {
        'role_id': _roleId,
        'memory_id': {'type': 'string'},
      },
      ['role_id', 'memory_id'],
      ToolEffect.write,
      (args) => _write(deleteMemory, args),
    ),
    assistantTool(
      revoke,
      '收回读某个角色聊天和记忆的授权（用户说不想让你看了时用）。',
      {'role_id': _roleId},
      ['role_id'],
      ToolEffect.readDiagnostic,
      (args) async {
        await grants.revoke('${args['role_id']}');
        return {'ok': true};
      },
    ),
  ];

  static const roleContext = 'aicove_role_context';

  static String? contextToolName(Map<String, dynamic> args) =>
      switch ((args['target'], args['action'])) {
        ('chat', 'read') => readChat,
        ('chat', 'append') => appendChat,
        ('chat', 'update' || 'write') => updateChat,
        ('chat', 'delete') => deleteChat,
        ('summary', 'read') => readSummary,
        ('summary', 'write' || 'update') => editSummary,
        ('summary', 'delete') => deleteSummary,
        ('memory', 'read') => readMemory,
        ('memory', 'write' || 'update') => writeMemory,
        ('memory', 'delete') => deleteMemory,
        _ => null,
      };

  static Map<String, dynamic> _contextArguments(Map<String, dynamic> args) =>
      Map<String, dynamic>.of(args)
        ..remove('target')
        ..remove('action');

  @override
  List<AITool> tools() {
    final atomic = _atomicTools();
    return [
      ...atomic,
      AITool(
        name: roleContext,
        description:
            '读取或管理其他角色的聊天记录（target="chat"）、话题摘要（target="summary"）与长期记忆（target="memory"）。'
            'action 支持：read 读取；append 追加聊天消息（仅 target="chat"）；'
            'update（或 write）修改指定内容（改聊天需传 message_id；写记忆需传 layer/title/content，不传 memory_id 时为新增；改摘要需传 summary 与 kind，可用 mode 指定仅改正文或整理当前话题）；'
            'delete 删除指定内容（删聊天传 message_ids，删记忆传 memory_id，删摘要传 kind）。'
            '摘要正文修改可撤销；聊天与记忆写删、摘要整理和删除不可撤销。',
        parameters: const {},
        inputSchema: {
          'type': 'object',
          'properties': {
            for (final tool in atomic.where((t) => t.name != revoke))
              ...tool.parameterSchema['properties'] as Map<String, dynamic>,
            'target': {
              'type': 'string',
              'enum': ['chat', 'summary', 'memory'],
              'description': '操作对象：chat 聊天记录、summary 话题摘要、memory 长期记忆',
            },
            'action': {
              'type': 'string',
              'enum': ['read', 'append', 'update', 'write', 'delete'],
              'description': '操作类型：read 读取、append 追加聊天、update/write 新增或修改、delete 删除',
            },
          },
          'required': ['target', 'action', 'role_id'],
        },
        effect: ToolEffect.write,
        handler: (args) async {
          final name = contextToolName(args);
          if (name == null) {
            return jsonEncode(assistantToolError('此 target 不支持这个 action'));
          }
          final tool = atomic.singleWhere((t) => t.name == name);
          final arguments = _contextArguments(args);
          final errors = validateToolArguments(
            arguments,
            tool.validationSchema ?? tool.parameterSchema,
          );
          if (errors.isNotEmpty) {
            return jsonEncode({'error': 'invalid', 'details': errors});
          }
          return tool.handler(arguments);
        },
      ),
    ];
  }

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      toolName == roleContext
      ? contextToolName(args) == null
            ? AssistantRisk.review
            : riskOf(contextToolName(args)!, _contextArguments(args))
      : _writes.contains(toolName)
      ? AssistantRisk.review
      : toolName == revoke || grants.current.contains('${args['role_id']}')
      ? AssistantRisk.readOnly
      : AssistantRisk.major;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    if (toolName == roleContext) {
      final atomic = contextToolName(args);
      if (atomic == null) {
        return const ApprovalPrompt(title: '上下文操作无效', detail: '请检查目标和操作');
      }
      return describe(atomic, _contextArguments(args));
    }
    final id = '${args['role_id']}';
    final role = rolesNow().where((r) => r.id == id && !r.isHidden).firstOrNull;
    if (_writes.contains(toolName)) {
      return ApprovalPrompt(
        title:
            '修改「${role?.displayName ?? id}」的${toolName == editSummary || toolName == deleteSummary
                ? '摘要'
                : toolName == writeMemory || toolName == deleteMemory
                ? '记忆'
                : '聊天记录'}',
        detail: '${args['summary'] ?? args['content'] ?? jsonEncode(args)}',
      );
    }
    return ApprovalPrompt(
      title: role == null
          ? '让 AIcove酱读角色 $id 的聊天记录和记忆'
          : '让 AIcove酱读「${role.displayName}」的聊天记录和记忆',
      detail: '同意后她以后可以直接读这个角色，内容会发给 AIcove酱用的模型；随时可以让她收回',
    );
  }

  /// Warms the grant cache so the first rating sees stored grants.
  Future<void> prepare() => grants.load();

  Future<Conversation?> _role(Object? id) async =>
      (await roles()).where((r) => r.id == '$id' && !r.isHidden).firstOrNull;

  /// Null when the read may go ahead. A user approval of this very call
  /// grants the role; otherwise the role must still be granted, so a read
  /// rated before a revoke cannot put the grant back.
  Future<Map<String, Object?>?> _authorize(String roleId) async {
    if (AssistantToolGate.unrestricted) return null;
    if (ToolCallScope.current?.outcome == GateOutcome.approved) {
      await grants.grant(roleId);
      return null;
    }
    if ((await grants.load()).contains(roleId)) return null;
    return assistantToolError('还没有读这个角色的授权，或刚被收回；需要时重新调用一次，会请用户同意');
  }

  static String _clip(String text) =>
      text.length <= _maxChars ? text : '${text.substring(0, _maxChars)}…（截断）';

  Future<Map<String, Object?>?> _authorizeWrite(String ownerId) async {
    if (!AssistantToolGate.unrestricted &&
        ToolCallScope.current?.outcome != GateOutcome.approved) {
      return assistantToolError('这次修改需要用户同意；读取授权不能代替修改审批');
    }
    return _authorize(ownerId);
  }

  Future<Map<String, Object?>> _savePrivateChange(
    String toolName,
    Map<String, Object?> before,
    Map<String, Object?> after,
    String description,
  ) async {
    final entry = await journal!.commitIf(
      toolName,
      ReversibleChange(
        kind: assistantPrivateDataChangeKind,
        description: description,
        before: before,
        after: after,
      ),
      () => changes!.applyIfCurrent(before, after),
    );
    if (entry == null) return assistantToolError('内容已变化，请重新读取后再修改');
    onChanged?.call();
    return {
      'ok': true,
      'change_id': entry.id,
      'before': before,
      'after': after,
    };
  }

  Future<Map<String, Object?>> _editSummary(Map<String, dynamic> args) async {
    final mode =
        args['mode'] ?? (args['kind'] != null ? 'update_current' : null);
    if (mode == 'compact_current_topic') return _write(editSummary, args);
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorizeWrite(role.id);
    if (refused != null) return refused;
    if (changes == null || journal == null) {
      return assistantToolError('摘要修改不可用');
    }
    if (mode != 'update_current') {
      return assistantToolError('请指定修改现有摘要或整理当前话题');
    }
    final kind = switch (args['kind']) {
      'manual' => ContextSummaryKind.manual,
      'auto' => ContextSummaryKind.auto,
      _ => null,
    };
    if (kind == null || args['summary'] is! String) {
      return assistantToolError('请指定摘要类型和新的摘要正文');
    }
    validateContextSummary(args['summary'] as String);
    final before = await changes!.summary(role.id, kind);
    if (before == null ||
        (args['summary_id'] != null && before['id'] != args['summary_id']) ||
        (args['expected_summary'] != null &&
            before['summary'] != args['expected_summary'])) {
      return assistantToolError('摘要已变化或已经失效，请重新读取');
    }
    return _savePrivateChange(editSummary, before, {
      ...before,
      'summary': (args['summary'] as String).trim(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, '修改「${role.displayName}」的摘要');
  }

  Future<Map<String, Object?>> _write(
    String tool,
    Map<String, dynamic> args,
  ) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorizeWrite(role.id);
    if (refused != null) return refused;
    if (writePrivate == null) return assistantToolError('此修改暂不可用');
    final result = await writePrivate!(tool, {...args, 'role_id': role.id});
    onChanged?.call();
    return result;
  }

  Future<Map<String, Object?>> _readChat(Map<String, dynamic> args) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorize(role.id);
    if (refused != null) return refused;
    if (rawMessages != null) return _readRawChat(role, args);
    final limit = (args['limit'] is num ? (args['limit'] as num).toInt() : 30)
        .clamp(1, _maxLines);
    final before = DateTime.tryParse('${args['before'] ?? ''}');
    final keyword = '${args['keyword'] ?? ''}'.trim();
    final lines = await messages(
      role.id,
      limit: limit,
      before: before,
      keyword: keyword.isEmpty ? null : keyword,
    );
    return {
      'role': role.displayName,
      'count': lines.length,
      'messages': [
        for (final line in lines)
          {
            'role': line.role,
            'at': line.at.toIso8601String(),
            'content': _clip(line.content),
          },
      ],
    };
  }

  Future<Map<String, Object?>> _readRawChat(
    Conversation role,
    Map<String, dynamic> args,
  ) async {
    final all = await rawMessages!(role.id);
    final boundary = readBoundary == null
        ? role.contextStartMessageId
        : await readBoundary!(role.id);
    final messageId = args['message_id'] as String?;
    final beforeId = args['before_message_id'] as String?;
    final afterId = args['after_message_id'] as String?;
    int? indexOf(String? id) =>
        id == null ? null : all.indexWhere((m) => m.id == id);
    final start = indexOf(boundary);
    final before = indexOf(beforeId);
    final after = indexOf(afterId);
    if ((before != null && before < 0) || (after != null && after < 0)) {
      return assistantToolError('指定的翻页消息不存在或不属于这个角色');
    }
    if (args['active_topic_only'] == true && boundary != null && start == -1) {
      return assistantToolError('当前话题边界已失效');
    }
    final keyword = (args['keyword'] as String? ?? '').trim();
    final legacyBefore = DateTime.tryParse('${args['before'] ?? ''}');
    final limit = (args['limit'] is num ? (args['limit'] as num).toInt() : 30)
        .clamp(1, _maxLines);
    final selected = <Message>[];
    for (var i = all.length - 1; i >= 0; i--) {
      final m = all[i];
      if (messageId != null && m.id != messageId) continue;
      if (args['active_topic_only'] == true && start != null && i <= start) {
        continue;
      }
      if (before != null && i >= before) continue;
      if (after != null && i <= after) continue;
      if (legacyBefore != null && !m.createdAt.isBefore(legacyBefore)) continue;
      if (keyword.isNotEmpty && !m.content.contains(keyword)) continue;
      selected.add(m);
      if (selected.length >= (messageId == null ? limit : 1)) break;
    }
    if (messageId != null && selected.isEmpty) {
      return assistantToolError('指定消息不存在或不属于这个角色');
    }
    return {
      'role': role.displayName,
      'context_start_message_id': boundary,
      'revision': contextSourceDigest(all),
      'count': selected.length,
      'messages': [
        for (final m in selected)
          {
            'id': m.id,
            'role': m.role,
            'at': m.createdAt.toIso8601String(),
            'status': m.status,
            'content': messageId == null ? _clip(m.content) : m.content,
          },
      ],
    };
  }

  Future<Map<String, Object?>> _readSummary(Map<String, dynamic> args) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorize(role.id);
    if (refused != null) return refused;
    if (summaryHistory == null) return assistantToolError('摘要读取不可用');
    final boundary = readBoundary == null
        ? role.contextStartMessageId
        : await readBoundary!(role.id);
    final entries = await summaryHistory!(role.id);
    Map<String, Object?> encode(ContextSummaryHistoryEntry entry) => {
      'id': entry.record.id,
      'kind': entry.record.kind.name,
      'boundary_id': entry.record.boundaryId,
      'topic_boundary': entry.record.topicBoundary,
      'summary': entry.record.summary,
      'created_at': entry.record.createdAt.toIso8601String(),
      'valid': entry.isValid,
      'current': entry.isCurrent,
    };
    final current = entries.where((entry) => entry.isCurrent && entry.isValid);
    final manual = current
        .where((entry) => entry.record.kind == ContextSummaryKind.manual)
        .firstOrNull;
    final auto = current
        .where((entry) => entry.record.kind == ContextSummaryKind.auto)
        .firstOrNull;
    return {
      'context_start_message_id': boundary,
      'manual': manual == null ? null : encode(manual),
      'auto': auto == null ? null : encode(auto),
      if (args['include_history'] == true)
        'history': [for (final entry in entries) encode(entry)],
    };
  }

  Future<Map<String, Object?>> _readMemory(Map<String, dynamic> args) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorize(role.id);
    if (refused != null) return refused;
    if (memoryItems != null) {
      final layer = args['layer'];
      if (layer != null && layer != 'core' && layer != 'archive') {
        return assistantToolError('记忆层只能是 core 或 archive');
      }
      final keyword = (args['keyword'] as String? ?? '').trim();
      final items = (await memoryItems!(role.id))
          .where(
            (item) =>
                (layer == null || item.layer.name == layer) &&
                (keyword.isEmpty ||
                    item.title.contains(keyword) ||
                    item.content.contains(keyword)),
          )
          .toList();
      return {
        'role': role.displayName,
        'count': items.length,
        'memories': [
          for (final item in items)
            {
              'id': item.id,
              'layer': item.layer.name,
              'title': item.title,
              'content': item.content,
              'locked': item.locked,
              'updated_at': item.updatedAt.toIso8601String(),
            },
        ],
      };
    }
    final items = await memories(role.id);
    return {
      'role': role.displayName,
      'count': items.length,
      'memories': [
        for (final item in items.take(_maxLines))
          {
            'title': item.title,
            'content': _clip(item.content),
            if (item.locked) 'locked': true,
          },
      ],
    };
  }
}
