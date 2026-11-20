// ignore_for_file: avoid_print
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import '../../agent_plugins/aicove_plugin.dart';
import '../../content_tags/domain/content_tag_registry.dart';
import '../domain/index.dart';
import '../prompts/plugin_prompts.dart';
import '../domain/handlers/ai_tool.dart';
import '../domain/handlers/tool_parameter.dart';
import 'trigger_agent_plugin.dart';
import 'trigger_config.dart';
import '../../auto_reply/data/auto_reply_trigger.dart';
import '../../auto_reply/data/auto_reply_trigger_controller.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/services/chat_history_store.dart';
import '../../settings/app_settings.dart';

/// (注释已丢失)
class TriggerPlugin extends BasePlugin {
  static const contentTags = StaticContentTagProvider(
    providerId: 'trigger',
    tagSpecs: [],
    toolNames: {'reminder'},
  );

  static const defaultReminderDescription = '''
管理当前会话的提醒。仅在用户明确要求设置、查询或取消提醒时调用；不要因为闲聊中提到时间就自动设置提醒。
action=create：创建提醒，必须提供 title 和 time，可用 prompt 指定触发时要说什么。
action=list：查询提醒；提供非空 query 时搜索，否则列出提醒，可用 include_completed 和 limit 控制结果。
action=delete：取消提醒，优先提供 id，不知道 id 时提供 query。''';

  // (注释已丢失)
  static final _metadata = PluginMetadata(
    id: 'trigger',
    name: '智能触发器',
    description: '允许 AI 根据对话设置定时提醒',
    version: '2.0.0',
    author: 'AIcove Team',
    icon: Icons.alarm,
    configSchema: {
      'enabled': ConfigField(
        type: ConfigFieldType.boolean,
        label: '启用插件',
        defaultValue: false,
      ),
    },
  );

  // (注释已丢失)
  TriggerConfig _triggerConfig;
  final Ref _ref;

  // (注释已丢失)
  TriggerPlugin(this._triggerConfig, this._ref) : super(metadata: _metadata);

  // ========== 重写 enabled getter ==========
  @override
  bool get enabled {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return _triggerConfig.enabled;
    final autoReply = settings.autoReplySettings;
    return autoReply.allowAiSetReminders ||
        autoReply.contactSettings.values.any(
          (contact) => contact.allowAiSetReminders == true,
        );
  }

  bool enabledForConversation(String? conversationId) {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return _triggerConfig.enabled;
    final id = conversationId?.trim() ?? '';
    final autoReply = settings.autoReplySettings;
    return id.isEmpty
        ? autoReply.allowAiSetReminders
        : autoReply.forContact(id).allowAiSetReminders;
  }

  @override
  AicovePlugin get agentPlugin => triggerAgentPlugin(this);

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

  // (注释已丢失)

  /// A non-null ID binds tools to one request; an empty ID denies access.
  /// Omitting it preserves the legacy active-conversation behavior.
  List<AITool> getTools({String? conversationId, PluginPrompts? prompts}) {
    if (!enabledForConversation(conversationId)) return [];

    final boundId = conversationId?.trim();
    return [_reminderTool(boundId, prompts ?? const PluginPrompts())];
  }

  AITool _reminderTool(String? conversationId, PluginPrompts prompts) =>
      AITool(
    name: 'reminder',
    description: prompts.of(PluginPromptSlot.reminderTool),
    parameters: const {
      'action': ToolParameter(
        type: 'string',
        description: '提醒操作：create 创建，list 查询，delete 取消',
        required: true,
        enumValues: ['create', 'list', 'delete'],
      ),
      'title': ToolParameter(type: 'string', description: '提醒标题；create 时必填'),
      'time': ToolParameter(
        type: 'string',
        description: '触发时间；create 时必填，支持 ISO 8601 或 HH:mm（自动判断今天/明天）',
      ),
      'prompt': ToolParameter(
        type: 'string',
        description: '触发时的指导提示，告诉你到时候该说什么',
      ),
      'id': ToolParameter(
        type: 'string',
        description: '要取消的提醒 ID；delete 时优先提供',
      ),
      'query': ToolParameter(
        type: 'string',
        description: '提醒搜索关键词；list 时可选，delete 不知道 id 时提供',
      ),
      'include_completed': ToolParameter(
        type: 'boolean',
        description: '查询时是否包含已完成、已作废的提醒（默认 false）',
      ),
      'limit': ToolParameter(
        type: 'integer',
        description: '查询最多返回多少条（列表默认 20，搜索默认 5）',
      ),
    },
    handler: (args) => switch (args['action']) {
      'create' => _handleCreateReminder(args, conversationId),
      'delete' => _handleDeleteReminder(args, conversationId),
      'list' =>
        (args['query'] as String? ?? '').trim().isNotEmpty
            ? _handleSearchReminders(args, conversationId)
            : _handleListReminders(args, conversationId),
      _ => Future.value(
        jsonEncode({
          'ok': false,
          'error': '请提供有效的 action：create、list 或 delete',
        }),
      ),
    },
  );

  // ========== 工具处理函数 ==========

  Future<String?> _handleCreateReminder(
    Map<String, dynamic> args,
    String? conversationId,
  ) async {
    final title = args['title'] as String? ?? '';
    final timeStr = args['time'] as String? ?? '';
    final suppliedPrompt = args['prompt'] as String?;
    final prompt = suppliedPrompt == null || suppliedPrompt.trim().isEmpty
        ? title
        : suppliedPrompt;

    if (title.isEmpty || timeStr.isEmpty) {
      return jsonEncode({'ok': false, 'error': '缺少必要参数 title 或 time'});
    }

    // (注释已丢失)
    final scheduledTime = _parseTime(timeStr);
    if (scheduledTime == null) {
      return jsonEncode({'ok': false, 'error': '无法解析时间格式：$timeStr'});
    }

    // 获取当前会话信息
    final convId = conversationId ?? _ref.read(activeConversationIdProvider);
    if (convId == null || convId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '当前没有活跃的会话'});
    }

    // (注释已丢失)
    final lastUserMessage =
        await _ref.read(chatHistoryStoreProvider).getLastUserMessage(convId);

    // (注释已丢失)
    final trigger =
        await _ref.read(autoReplyTriggersProvider.notifier).createTrigger(
              title: title,
              type: AutoReplyTriggerType.fixed,
              nextFireAt: scheduledTime,
              allowNight: true,
              requireExact: false,
              delayMinutes: 0,
              prompt: prompt,
              priority: AutoReplyTriggerPriority.high, // (注释已丢失)
              source: TriggerSource.userRequest,
              conversationId: convId,
              contextLastUserMessageId: lastUserMessage?.id,
              contextLastUserMessageAt: lastUserMessage?.createdAt,
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

  Future<String?> _handleDeleteReminder(
    Map<String, dynamic> args,
    String? conversationId,
  ) async {
    if (conversationId != null && conversationId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '当前没有活跃的会话'});
    }

    final id = (args['id'] as String?)?.trim();
    final query = (args['query'] as String?)?.trim();

    final convId = conversationId ?? _ref.read(activeConversationIdProvider);

    // (注释已丢失)
    if (id != null && id.isNotEmpty) {
      final allTriggers = _ref.read(autoReplyTriggersProvider).valueOrNull ??
          const <AutoReplyTrigger>[];
      final target = allTriggers.where((t) => t.id == id).firstOrNull;
      if (target == null) {
        return jsonEncode({'ok': false, 'error': '未找到该提醒'});
      }
      if (convId != null &&
          convId.isNotEmpty &&
          target.conversationId != convId) {
        return jsonEncode({'ok': false, 'error': '只能删除当前会话的提醒'});
      }
      await _ref.read(autoReplyTriggersProvider.notifier).deleteTrigger(id);
      AppLogger.info('TriggerPlugin', '通过工具调用删除触发器', metadata: {'id': id});
      return jsonEncode({
        'ok': true,
        'result': {'message': '好的，已经取消了这个提醒'},
      });
    }

    // (注释已丢失)
    if (query == null || query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '请告诉我要取消哪个提醒（例如"起床闹钟"）'});
    }

    final candidates =
        _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
              query: query,
              conversationId: convId,
              includeCompleted: false,
              limit: 5,
            );

    if (candidates.isEmpty) {
      return jsonEncode({'ok': false, 'error': '没找到匹配 "$query" 的提醒'});
    }

    if (candidates.length > 1) {
      final preview =
          candidates.take(3).map((t) => '${t.title} (id: ${t.id})').join(', ');
      return jsonEncode({
        'ok': false,
        'error': '找到多条匹配提醒：$preview。请指定要取消的 id。',
        'candidates': candidates
            .map((t) => {
                  'id': t.id,
                  'title': t.title,
                  'next_fire_at': t.nextFireAt.toIso8601String(),
                })
            .toList(),
      });
    }

    final target = candidates.first;
    await _ref
        .read(autoReplyTriggersProvider.notifier)
        .deleteTrigger(target.id);
    AppLogger.info('TriggerPlugin', '通过工具调用删除触发器(query)', metadata: {
      'query': query,
      'id': target.id,
    });

    return jsonEncode({
      'ok': true,
      'result': {'message': '好的，已取消：${target.title}'},
    });
  }

  Future<String?> _handleListReminders(
    Map<String, dynamic> args,
    String? conversationId,
  ) async {
    if (conversationId != null && conversationId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '当前没有活跃的会话'});
    }

    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 20;

    final convId = conversationId ?? _ref.read(activeConversationIdProvider);
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

  Future<String?> _handleSearchReminders(
    Map<String, dynamic> args,
    String? conversationId,
  ) async {
    if (conversationId != null && conversationId.isEmpty) {
      return jsonEncode({'ok': false, 'error': '当前没有活跃的会话'});
    }

    final query = args['query'] as String? ?? '';
    final includeCompleted = args['include_completed'] as bool? ?? false;
    final limit = (args['limit'] as num?)?.toInt() ?? 5;

    if (query.isEmpty) {
      return jsonEncode({'ok': false, 'error': '请提供搜索关键词'});
    }

    final convId = conversationId ?? _ref.read(activeConversationIdProvider);
    final candidates =
        _ref.read(autoReplyTriggersProvider.notifier).searchTriggers(
              query: query,
              conversationId: convId,
              includeCompleted: includeCompleted,
              limit: limit,
            );

    return jsonEncode({
      'ok': true,
      'result': candidates
          .map((t) => {
                'id': t.id,
                'title': t.title,
                'next_fire_at': t.nextFireAt.toIso8601String(),
                'status': t.status.name,
                'priority': t.priority.name,
              })
          .toList(),
    });
  }

  // ========== 保留兼容：XML 标签解析（标记废弃） ==========

  /// Legacy `<create_trigger>`/`<delete_trigger>` tags: removed from the
  /// text; executed only when the XML fallback is on (AR-040).
  Future<PluginProcessResult> handleLegacyTriggerTags(String text) async {
    if (!enabled) {
      return PluginProcessResult(processedText: text, events: []);
    }

    final createRegex =
        RegExp(r'<create_trigger\s[^>]*?>', caseSensitive: false);
    final deleteRegex =
        RegExp(r'<delete_trigger\s[^>]*?>', caseSensitive: false);
    final containsLegacyTags = text.contains('<create_trigger') ||
        text.contains('<delete_trigger');
    if (containsLegacyTags) {
      AppLogger.warning('TriggerPlugin', 'AI 使用了废弃的 XML 标签格式，应使用原生工具调用');
    }

    // XML 兜底默认下线（AR-040）：只清理标签展示，不再执行触发器增删
    // Legacy response processing has no conversation scope; retain its global
    // opt-in instead of activating it through another role's native tools.
    if (!_triggerConfig.xmlFallbackEnabled || !enabledForConversation(null)) {
      if (!containsLegacyTags) {
        return PluginProcessResult(processedText: text, events: []);
      }
      AppLogger.warning(
          'TriggerPlugin', 'XML 兜底已停用，忽略标签指令（仅清理展示文本）');
      return PluginProcessResult(
        processedText: text
            .replaceAll(createRegex, '')
            .replaceAll(deleteRegex, '')
            .trim(),
        events: const [],
      );
    }

    final events = <PluginEvent>[];
    String processedText = text;

    // Handle <create_trigger>
    final createMatches = createRegex.allMatches(text);
    for (final match in createMatches) {
      final attrString = match.group(0) ?? '';
      final timeMatch = RegExp(r'time="([^"]+)"').firstMatch(attrString);
      final titleMatch = RegExp(r'title="([^"]+)"').firstMatch(attrString);
      final promptMatch = RegExp(r'prompt="([^"]+)"').firstMatch(attrString);
      final contactIdMatch =
          RegExp(r'contact_id="([^"]+)"').firstMatch(attrString);

      if (timeMatch != null) {
        final timeStr = timeMatch.group(1)!;
        final title = titleMatch?.group(1) ?? 'Active Reply';
        final prompt = promptMatch?.group(1);
        final contactId = contactIdMatch?.group(1);

        final scheduledTime = _parseTime(timeStr);

        if (scheduledTime != null) {
          final convId =
              contactId ?? _ref.read(activeConversationIdProvider) ?? '';
          AppLogger.info('TriggerPlugin',
              'Creating trigger (XML fallback): $title at $scheduledTime');
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
    final deleteMatches = deleteRegex.allMatches(text);
    for (final match in deleteMatches) {
      final attrString = match.group(0) ?? '';
      final idMatch = RegExp(r'id="([^"]+)"').firstMatch(attrString);

      if (idMatch != null) {
        final triggerId = idMatch.group(1)!;
        AppLogger.info(
            'TriggerPlugin', 'Deleting trigger (XML fallback): $triggerId');
        await _ref
            .read(autoReplyTriggersProvider.notifier)
            .deleteTrigger(triggerId);

        events.add(PluginEvent(
          pluginId: id,
          type: 'trigger_deleted',
          data: {'id': triggerId},
        ));
      }
    }

    // Remove tags from text
    processedText =
        text.replaceAll(createRegex, '').replaceAll(deleteRegex, '').trim();

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
    final isToday =
        time.day == now.day && time.month == now.month && time.year == now.year;
    final isTomorrow = time.day == now.day + 1 &&
        time.month == now.month &&
        time.year == now.year;

    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (isToday) return '今天 $timeStr';
    if (isTomorrow) return '明天 $timeStr';
    return '${time.month}月${time.day}日 $timeStr';
  }
}
