import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope, ToolEffect;
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/conversation.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import 'assistant_review.dart';
import 'assistant_tool_group.dart';

/// One chat message as the assistant reads it.
typedef AssistantChatLine = ({String role, String content, DateTime at});

/// One long-term memory as the assistant reads it.
typedef AssistantMemoryLine = ({String title, String content, bool locked});

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

  static const readChat = 'aicove_read_role_chat';
  static const readMemory = 'aicove_read_role_memory';
  static const revoke = 'aicove_revoke_read';

  static const _maxLines = 80;
  static const _maxChars = 1500;

  static const _roleId = {
    'type': 'string',
    'description': 'aicove_list_roles 给出的角色 id',
  };

  @override
  List<AITool> tools() => [
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
      },
      ['role_id'],
      ToolEffect.readPrivate,
      _readChat,
    ),
    assistantTool(
      readMemory,
      '读某个角色的长期记忆（记忆 Agent 整理的和用户锁定的）。授权规则同 $readChat。',
      {'role_id': _roleId},
      ['role_id'],
      ToolEffect.readPrivate,
      _readMemory,
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

  @override
  AssistantRisk riskOf(String toolName, Map<String, dynamic> args) =>
      toolName == revoke || grants.current.contains('${args['role_id']}')
      ? AssistantRisk.readOnly
      : AssistantRisk.major;

  @override
  ApprovalPrompt describe(String toolName, Map<String, dynamic> args) {
    final id = '${args['role_id']}';
    final role = rolesNow()
        .where((r) => r.id == id && !r.isHidden)
        .firstOrNull;
    return ApprovalPrompt(
      title: role == null
          ? '让 AIcove酱读角色 $id 的聊天记录和记忆'
          : '让 AIcove酱读「${role.displayName}」的聊天记录和记忆',
      detail: '同意后她以后可以直接读这个角色，内容会发给 AIcove酱用的模型；随时可以让她收回',
    );
  }

  /// Warms the grant cache so the first rating sees stored grants.
  Future<void> prepare() => grants.load();

  Future<Conversation?> _role(Object? id) async => (await roles())
      .where((r) => r.id == '$id' && !r.isHidden)
      .firstOrNull;

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

  Future<Map<String, Object?>> _readChat(Map<String, dynamic> args) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorize(role.id);
    if (refused != null) return refused;
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

  Future<Map<String, Object?>> _readMemory(Map<String, dynamic> args) async {
    final role = await _role(args['role_id']);
    if (role == null) return assistantToolError('没有这个角色：${args['role_id']}');
    final refused = await _authorize(role.id);
    if (refused != null) return refused;
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
