// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../domain/index.dart';
import '../domain/handlers/ai_tool.dart';
import '../domain/handlers/tool_parameter.dart';
import 'trigger_config.dart';
import '../../chat/data/auto_reply_trigger.dart';
import '../../chat/data/auto_reply_trigger_controller.dart';
import '../../chat/conversation_providers.dart';

/// 智能触发器插件
/// 允许 AI 根据对话设置定时提醒
class TriggerPlugin extends BasePlugin {
  // ========== 元数据定义 ==========
  static final _metadata = PluginMetadata(
    id: 'trigger',
    name: '智能触发器',
    description: '允许AI根据对话设置定时提醒',
    version: '2.0.0',
    author: 'MyGril Team',
    icon: Icons.alarm,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
    },
  );

  // ========== 内部状态 ==========
  TriggerConfig _triggerConfig;
  final Ref _ref;

  // ========== 构造函数 ==========
  TriggerPlugin(this._triggerConfig, this._ref) : super(metadata: _metadata);

  // ========== 重写 enabled getter ==========
  @override
  bool get enabled => _triggerConfig.enabled;

  // ========== 生命周期方法 ==========

  @override
  Future<void> onInitialize() async {
    await super.onInitialize();
    debugPrint('[TriggerPlugin] 初始化完成');
  }

  @override
  Future<void> onConfigChanged(Map<String, dynamic> newConfig) async {
    _triggerConfig = TriggerConfig.fromJson(newConfig);
    debugPrint('[TriggerPlugin] 配置已更新');
  }

  // ========== 现有功能（保留） ==========

  @override
  Map<String, dynamic> getConfig() => _triggerConfig.toJson();

  @override
  void updateConfig(Map<String, dynamic> config) {
    _triggerConfig = TriggerConfig.fromJson(config);
  }

  @override
  Future<String?> getSystemPrompt({String? userMessage, bool supportsToolCalling = false}) async {
    if (!enabled) return null;

    // 当支持原生工具调用时，检查用户消息是否涉及提醒相关
    if (supportsToolCalling && userMessage != null) {
      final lowerMsg = userMessage.toLowerCase();
      final isReminderRelated = lowerMsg.contains('提醒') ||
          lowerMsg.contains('闹钟') ||
          lowerMsg.contains('叫我') ||
          lowerMsg.contains('remind') ||
          lowerMsg.contains('alarm') ||
          lowerMsg.contains('取消') ||
          lowerMsg.contains('删掉') ||
          lowerMsg.contains('有哪些') ||
          lowerMsg.contains('查看');

      if (isReminderRelated) {
        return '''
你可以使用以下工具来管理提醒：
- create_reminder: 当用户要求设置提醒/闹钟时使用
- delete_reminder: 当用户要求取消提醒时使用
- list_reminders: 当用户想查看提醒列表时使用
- search_reminders: 当用户想搜索特定提醒时使用

请根据用户的需求选择合适的工具。
''';
      }
    }

    return null;
  }

  // ========== 新增：工具注册 ==========

  @override
  List<AITool> getTools() {
    if (!enabled) return [];

    return [
      _createReminderTool,
      _deleteReminderTool,
      _listRemindersTool,
      _searchRemindersTool,
    ];
  }

  AITool get _createReminderTool => AITool(
    name: 'create_reminder',
    description: '''
创建一个定时提醒。当用户明确要求设置提醒、闹钟、定时任务时调用此工具。

使用场景：
- "明天早上8点叫我起床"
- "2小时后提醒我喝水"
- "下午3点提醒我开会"

不要在用户没有明确要求时调用此工具。
''',
    parameters: {
      'title': ToolParameter(
        type: 'string',
        description: '提醒的标题/描述，简洁说明这个提醒是干什么的',
        required: true,
      ),
      'time': ToolParameter(
        type: 'string',
        description: '触发时间。支持格式：ISO 8601（2026-01-27T08:00:00）或简单时间（08:00，会自动判断今天/明天）',
        required: true,
      ),
      'prompt': ToolParameter(
        type: 'string',
        description: '触发时的指导提示，告诉你到时候该说什么',
        required: false,
      ),
    },
    handler: _handleCreateReminder,
  );

  AITool get _deleteReminderTool => AITool(
    name: 'delete_reminder',
    description: '''
删除一个已存在的提醒。当用户要求取消、删除某个提醒时调用。

使用场景：
- "取消明天的闹钟"
- "不用提醒我了"
- "把那个提醒删掉"

参数规则：
- 优先传 id（最准确）
- 如果没有 id，请传 query（例如"明天早上叫我起床"/"起床闹钟"），工具内部会 search
''',
    parameters: {
      'id': ToolParameter(
        type: 'string',
        description: '要删除的提醒ID（如果已知，优先提供）',
        required: false,
      ),
      'query': ToolParameter(
        type: 'string',
        description: '不知道 id 时使用：用一句话描述你要取消的提醒（例如"明天早上叫我起床"）',
        required: false,
      ),
    },
    handler: _handleDeleteReminder,
  );

  AITool get _listRemindersTool => AITool(
    name: 'list_reminders',
    description: '''
列出提醒列表（触发器列表）。当用户问"我有哪些提醒/闹钟/待办"时调用。
返回 JSON 数组，包含每条提醒的 id/title/next_fire_at/status/priority 等。
''',
    parameters: {
      'include_completed': ToolParameter(
        type: 'boolean',
        description: '是否包含已完成/已作废的提醒（默认 false）',
        required: false,
      ),
      'limit': ToolParameter(
        type: 'integer',
        description: '最多返回多少条（默认 20）',
        required: false,
      ),
    },
    handler: _handleListReminders,
  );

  AITool get _searchRemindersTool => AITool(
    name: 'search_reminders',
    description: '''
搜索提醒列表。适用于：用户说"把那个起床提醒删掉/取消明天的闹钟"但没有 id。
返回 JSON 数组，包含候选提醒的 id/title/next_fire_at 等。
''',
    parameters: {
      'query': ToolParameter(
        type: 'string',
        description: '搜索关键词/自然语言描述（例如"起床""明天早上8点""开会提醒"）',
        required: true,
      ),
      'include_completed': ToolParameter(
        type: 'boolean',
        description: '是否包含已完成/已作废的提醒（默认 false）',
        required: false,
      ),
      'limit': ToolParameter(
        type: 'integer',
        description: '最多返回多少条（默认 5）',
        required: false,
      ),
    },
    handler: _handleSearchReminders,
  );

  // ========== 工具处理函数 ==========

  Future<String?> _handleCreateReminder(Map<String, dynamic> args) async {
    final title = args['title'] as String? ?? '';
    final timeStr = args['time'] as String? ?? '';
    final prompt = args['prompt'] as String?;

    if (title.isEmpty || timeStr.isEmpty) {
      return jsonEncode({'ok': false, 'error': '缺少必要参数 title 或 time'});
    }

    // 解析时间
    final scheduledTime = _parseTime(timeStr);
    if (scheduledTime == null) {
      return jsonEncode({'ok': false, 'error': '无法解析时间格式：$timeStr'});
    }

    // 获取当前会话信息
    final convId = _ref.read(activeConversationIdProvider);
    if (convId == null || convId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '当前没有活跃的会话'});
    }

    // 获取会话中最后一条用户消息（用于作废判断）
    final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == convId).firstOrNull;

    String? lastUserMsgId;
    DateTime? lastUserMsgAt;
    if (conv != null) {
      for (final m in conv.messages.reversed) {
        if (m.role == 'user') {
          lastUserMsgId = m.id;
          lastUserMsgAt = m.createdAt;
          break;
        }
      }
    }

    // 创建触发器
    final trigger = await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
      title: title,
      type: AutoReplyTriggerType.fixed,
      nextFireAt: scheduledTime,
      allowNight: true,
      requireExact: false,
      delayMinutes: 0,
      prompt: prompt,
      priority: AutoReplyTriggerPriority.high, // 用户要求 = 高优先级
      source: TriggerSource.userRequest,
      conversationId: convId,
      contextLastUserMessageId: lastUserMsgId,
      contextLastUserMessageAt: lastUserMsgAt,
    );

    AppLogger.info('TriggerPlugin', '通过工具调用创建触发器', metadata: {
      'title': title,
      'time': scheduledTime.toIso8601String(),
      'triggerId': trigger.id,
    });

    return jsonEncode({
      'ok': true,
      'result': {
        'id': trigger.id,
        'title': trigger.title,
        'time': _formatTime(scheduledTime),
        'message': '好的，我会在 ${_formatTime(scheduledTime)} 提醒你～',
      },
    });
  }

  Future<String?> _handleDeleteReminder(Map<String, dynamic> args) async {
    final id = (args['id'] as String?)?.trim();
    final query = (args['query'] as String?)?.trim();

    final convId = _ref.read(activeConversationIdProvider);

    // 1) 优先按 id 删除（最准确）
    if (id != null && id.isNotEmpty) {
      await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(id);
      AppLogger.info('TriggerPlugin', '通过工具调用删除触发器', metadata: {'id': id});
      return jsonEncode({
        'ok': true,
        'result': {'message': '好的，已经取消了这个提醒'},
      });
    }

    // 2) 否则按 query 删除：先在当前会话里搜索匹配的提醒
    if (query == null || query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '请告诉我要取消哪个提醒（例如"起床闹钟"）'});
    }

    final candidates = _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
      query: query,
      conversationId: convId,
      includeCompleted: false,
      limit: 5,
    );

    if (candidates.isEmpty) {
      return jsonEncode({'ok': false, 'error': '没找到匹配"$query"的提醒'});
    }

    if (candidates.length > 1) {
      final preview = candidates.take(3).map((t) => '「${t.title}」(id: ${t.id})').join('、');
      return jsonEncode({
        'ok': false,
        'error': '找到了多条匹配的提醒：$preview… 请指定要取消哪一个（可以用 id）',
        'candidates': candidates.map((t) => {
          'id': t.id,
          'title': t.title,
          'next_fire_at': t.nextFireAt.toIso8601String(),
        }).toList(),
      });
    }

    final target = candidates.first;
    await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(target.id);
    AppLogger.info('TriggerPlugin', '通过工具调用删除触发器(query)', metadata: {
      'query': query,
      'id': target.id,
    });

    return jsonEncode({
      'ok': true,
      'result': {'message': '好的，已取消：${target.title}'},
    });
  }

  Future<String?> _handleListReminders(Map<String, dynamic> args) async {
    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 20;

    final convId = _ref.read(activeConversationIdProvider);
    final triggers = _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];

    final filtered = triggers
        .where((t) {
          if (convId != null && t.conversationId != convId) return false;
          if (!includeCompleted && !t.isActive) return false;
          return true;
        })
        .take(limit)
        .map((t) => {
          'id': t.id,
          'title': t.title,
          'next_fire_at': t.nextFireAt.toIso8601String(),
          'status': t.status.name,
          'priority': t.priority.name,
        })
        .toList();

    return jsonEncode({
      'ok': true,
      'result': filtered,
    });
  }

  Future<String?> _handleSearchReminders(Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';
    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 5;

    if (query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '请提供搜索关键词'});
    }

    final convId = _ref.read(activeConversationIdProvider);
    final candidates = _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
      query: query,
      conversationId: convId,
      includeCompleted: includeCompleted,
      limit: limit,
    );

    return jsonEncode({
      'ok': true,
      'result': candidates.map((t) => {
        'id': t.id,
        'title': t.title,
        'next_fire_at': t.nextFireAt.toIso8601String(),
        'status': t.status.name,
        'priority': t.priority.name,
      }).toList(),
    });
  }

  // ========== 保留兼容：XML 标签解析（标记废弃） ==========

  @override
  @Deprecated('请使用原生工具调用，此方法仅作为兜底兼容')
  Future<PluginProcessResult> processResponse(String text) async {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    // 检测是否使用了废弃的 XML 标签格式
    if (text.contains('<create_trigger') || text.contains('<delete_trigger')) {
      AppLogger.warning('TriggerPlugin', 'AI 使用了废弃的 XML 标签格式，应使用原生工具调用');
    }

    final events = <PluginEvent>[];
    String processedText = text;

    // Handle <create_trigger>
    final createRegex = RegExp(r'<create_trigger\s[^>]*?>', caseSensitive: false);
    final createMatches = createRegex.allMatches(text);
    for (final match in createMatches) {
      final attrString = match.group(0) ?? '';
      final timeMatch = RegExp(r'time="([^"]+)"').firstMatch(attrString);
      final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(attrString);
      final promptMatch = RegExp(r'prompt="([^"]+)"').firstMatch(attrString);
      final contactIdMatch = RegExp(r'contact_id="([^"]+)"').firstMatch(attrString);

      if (timeMatch != null) {
        final timeStr = timeMatch.group(1)!;
        final title = titleMatch?.group(1) ?? 'Active Reply';
        final prompt = promptMatch?.group(1);
        final contactId = contactIdMatch?.group(1);

        final scheduledTime = _parseTime(timeStr);

        if (scheduledTime != null) {
          final convId = contactId ?? _ref.read(activeConversationIdProvider) ?? '';
          AppLogger.info('TriggerPlugin', 'Creating trigger (XML fallback): $title at $scheduledTime');
          await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
            title: title,
            type: AutoReplyTriggerType.fixed,
            nextFireAt: scheduledTime,
            allowNight: true,
            requireExact: false,
            delayMinutes: 0,
            prompt: prompt,
            priority: AutoReplyTriggerPriority.high,
            source: TriggerSource.userRequest,
            conversationId: convId,
          );

          events.add(PluginEvent(
            pluginId: id,
            type: 'trigger_created',
            data: {
              'time': scheduledTime.toIso8601String(),
              'title': title,
            },
          ));
        }
      }
    }

    // Handle <delete_trigger>
    final deleteRegex = RegExp(r'<delete_trigger\s[^>]*?>', caseSensitive: false);
    final deleteMatches = deleteRegex.allMatches(text);
    for (final match in deleteMatches) {
      final attrString = match.group(0) ?? '';
      final idMatch = RegExp(r'id="([^"]+)"').firstMatch(attrString);

      if (idMatch != null) {
        final triggerId = idMatch.group(1)!;
        AppLogger.info('TriggerPlugin', 'Deleting trigger (XML fallback): $triggerId');
        await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(triggerId);

        events.add(PluginEvent(
          pluginId: id,
          type: 'trigger_deleted',
          data: {'id': triggerId},
        ));
      }
    }

    // Remove tags from text
    processedText = text.replaceAll(createRegex, '').replaceAll(deleteRegex, '').trim();

    return PluginProcessResult(
      processedText: processedText,
      events: events,
    );
  }

  // ========== 辅助方法 ==========

  DateTime? _parseTime(String timeStr) {
    // 尝试 ISO 8601 格式
    try {
      return DateTime.parse(timeStr);
    } catch (_) {}

    // 尝试 HH:mm 格式
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final now = DateTime.now();
        var d = DateTime(now.year, now.month, now.day, h, m);
        if (d.isBefore(now)) {
          d = d.add(const Duration(days: 1));
        }
        return d;
      }
    } catch (_) {}

    return null;
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final isToday = time.day == now.day && time.month == now.month && time.year == now.year;
    final isTomorrow = time.day == now.day + 1 && time.month == now.month && time.year == now.year;

    final timeStr = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (isToday) return '今天 $timeStr';
    if (isTomorrow) return '明天 $timeStr';
    return '${time.month}月${time.day}日 $timeStr';
  }
}
