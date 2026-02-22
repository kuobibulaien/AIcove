import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/app_logger.dart';
import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';
import 'background_service.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';

final contextAnalyzerProvider = Provider((ref) => ContextAnalyzer(ref));

class ContextAnalyzer {
  final Ref _ref;
  final AgentApiClient _agent = AgentApiClient();

  ContextAnalyzer(this._ref);

  Future<void> analyzeAndSchedule(Conversation conversation) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final autoReplySettings = settings.autoReplySettings;
    if (!autoReplySettings.enabled) return;

    final history = conversation.messages;
    // Only analyze last 10 messages to save tokens
    final recent =
        history.length > 10 ? history.sublist(history.length - 10) : history;

    // 根据时间增强插件配置决定是否添加时间戳
    final pluginManager = _ref.read(pluginManagerProvider);
    final timeAwarenessPlugin =
        pluginManager.getPlugin('time_awareness') as TimeAwarenessPlugin?;
    final includeTimestamp =
        timeAwarenessPlugin?.shouldIncludeTimestamp ?? false;
    final messagesJson = recent
        .map((m) => m.toHistoryJson(includeTimestamp: includeTimestamp))
        .toList();

    // 获取当前未完成的触发器列表
    final currentTriggers =
        _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];
    final pendingTriggers = currentTriggers
        .where((t) =>
            t.isActive &&
            t.conversationId == conversation.id &&
            t.source == TriggerSource.aiScheduler)
        .toList();

    // 默认提示词
    const defaultPrompt = '''
You are the "Scheduler" for an AI girlfriend. Your job is to analyze the chat history and decide if you should schedule a future message to the user.
Rules:
1. Look for cues: User going to sleep -> Schedule "Good morning" (allowNight: false). User going to work -> Schedule "Lunch break" check-in. User watching movie -> Schedule "How was it?"
2. If no specific event is found, do NOT schedule anything.
3. Output strictly JSON list of triggers.
4. Assign a priority: "high" (critical alarms), "medium" (normal context), "low" (casual/emotional/miss you).
Format:
[
  {
    "title": "Description of why this trigger exists",
    "delay_minutes": 60,
    "allow_night": false,
    "priority": "medium",
    "prompt": "System prompt for the AI when it wakes up. e.g. 'It is morning now, say good morning to user.'"
  }
]
If no triggers, return [].
Do not output markdown. Just JSON.
''';

    // 构建系统消息，包含现有触发器信息
    final analyzerPrompt = autoReplySettings.analyzerPrompt.trim().isNotEmpty
        ? autoReplySettings.analyzerPrompt
        : defaultPrompt;
    final systemContent = StringBuffer(analyzerPrompt);
    if (pendingTriggers.isNotEmpty) {
      systemContent.write('\n\nEXISTING PENDING TRIGGERS:\n');
      systemContent.write(jsonEncode(pendingTriggers
          .map((t) => {
                'id': t.id,
                'title': t.title,
                'delay_minutes': t.delayMinutes,
                'allow_night': t.allowNight,
                'priority': t.priority.name,
                'next_fire_at': t.nextFireAt.toIso8601String(),
              })
          .toList()));
    }

    messagesJson.add({
      'role': 'system',
      'content': systemContent.toString(),
    });

    try {
      // 优先使用配置的独立 AI 管家模型，否则使用默认对话模型
      // 无论哪种情况，都使用新的 sessionId 隔离上下文，防止污染
      final String model;
      final String provider;

      if (autoReplySettings.analyzerModel?.isNotEmpty == true) {
        // 使用用户指定的独立模型
        final analyzerRef = autoReplySettings.analyzerModel!;
        model = settings.getRawModelId(analyzerRef);
        provider = autoReplySettings.analyzerProvider?.isNotEmpty == true
            ? autoReplySettings.analyzerProvider!
            : (settings.getModelProviderId(analyzerRef) ?? 'openai');
        AppLogger.info('ContextAnalyzer', '使用独立 AI 管家模型', metadata: {
          'model': model,
          'provider': provider,
        });
      } else {
        // 使用默认对话模型（但仍隔离 session）
        final defaultRef = settings.defaultModelName;
        model = settings.getRawModelId(defaultRef);
        provider = settings.getModelProviderId(defaultRef) ?? 'openai';
        AppLogger.info('ContextAnalyzer', '使用默认模型（隔离 session）', metadata: {
          'model': model,
          'provider': provider,
        });
      }

      final modelFull = '$provider:$model';
      final providerAuth = settings.providers.firstWhere(
        (p) => p.id == provider,
        orElse: () => ProviderAuth(
            id: provider, apiKeys: [], apiBaseUrl: settings.apiBaseUrl),
      );
      final apiKey =
          providerAuth.apiKeys.isNotEmpty ? providerAuth.apiKeys.first : null;
      final apiBase = providerAuth.apiBaseUrl.isNotEmpty
          ? providerAuth.apiBaseUrl
          : settings.apiBaseUrl;

      // 关键：使用独立的 sessionId，完全隔离触发器分析与聊天上下文
      final isolatedSessionId =
          'scheduler_${DateTime.now().millisecondsSinceEpoch}';

      final response = await _agent.sendMessage(
        agentId: 'scheduler',
        sessionId: isolatedSessionId,
        modelFullId: modelFull,
        messages: messagesJson,
        userText: '',
        temperature: 0.3, // Low temp for JSON
        token: settings.backendApiKey,
        providerApiBase: apiBase,
        providerApiKey: apiKey,
      );

      await _processResponse(
          jsonStr: response,
          conversation: conversation,
          settings: settings,
          apiKey: apiKey,
          apiBase: apiBase,
          model: modelFull);
    } catch (e) {
      AppLogger.error('ContextAnalyzer', 'Failed to analyze context',
          metadata: {'error': e.toString()});
    }
  }

  Future<void> _processResponse({
    required String jsonStr,
    required Conversation conversation,
    required AppSettings settings,
    String? apiKey,
    String? apiBase,
    String? model,
  }) async {
    try {
      // Clean up markdown if present
      var clean = jsonStr.trim();
      if (clean.startsWith('```json')) clean = clean.substring(7);
      if (clean.startsWith('```')) clean = clean.substring(3);
      if (clean.endsWith('```')) clean = clean.substring(0, clean.length - 3);
      clean = clean.trim();

      final List<dynamic> aiTriggers = jsonDecode(clean);
      final controller = _ref.read(autoReplyTriggersProvider.notifier);

      final currentTriggers =
          _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];
      final pendingTriggers = currentTriggers
          .where((t) =>
              t.isActive &&
              t.conversationId == conversation.id &&
              t.source == TriggerSource.aiScheduler)
          .toList();

      final aiTriggerIds = <String>{};
      final triggersToAdd = <Map<String, dynamic>>[];
      final snapshotSource = conversation.messages.length > 10
          ? conversation.messages.sublist(conversation.messages.length - 10)
          : conversation.messages;
      final contextSnapshot = jsonEncode(
        snapshotSource.map((m) => m.toHistoryJson()).toList(),
      );

      for (final item in aiTriggers) {
        if (item is Map<String, dynamic>) {
          final existingId = item['id'] as String?;
          if (existingId != null && existingId.isNotEmpty) {
            aiTriggerIds.add(existingId);
          } else {
            triggersToAdd.add(item);
          }
        }
      }

      // 删除过期的
      for (final existing in pendingTriggers) {
        if (!aiTriggerIds.contains(existing.id)) {
          await controller.deleteTrigger(existing.id);
        }
      }

      // 添加新的
      for (final item in triggersToAdd) {
        final title = item['title'] as String? ?? 'Auto Trigger';
        final minutes = (item['delay_minutes'] as num?)?.toInt() ?? 60;
        final allowNight = item['allow_night'] as bool? ?? false;
        final prompt = item['prompt'] as String? ??
            'Initiate conversation based on trigger: $title';
        final priorityStr = item['priority'] as String? ?? 'medium';

        AutoReplyTriggerPriority priority;
        switch (priorityStr.toLowerCase()) {
          case 'high':
            priority = AutoReplyTriggerPriority.high;
            break;
          case 'low':
            priority = AutoReplyTriggerPriority.low;
            break;
          default:
            priority = AutoReplyTriggerPriority.medium;
        }

        // 获取会话中最后一条用户消息（用于作废判断）
        String? lastUserMsgId;
        DateTime? lastUserMsgAt;
        for (final m in conversation.messages.reversed) {
          if (m.role == 'user') {
            lastUserMsgId = m.id;
            lastUserMsgAt = m.createdAt;
            break;
          }
        }

        // 1. 使用新的 createTrigger 方法创建触发器
        final createdTrigger = await controller.createTrigger(
          title: title,
          type: AutoReplyTriggerType.delay,
          nextFireAt: DateTime.now().add(Duration(minutes: minutes)),
          allowNight: allowNight,
          requireExact: false,
          delayMinutes: minutes,
          prompt: prompt,
          priority: priority,
          source: TriggerSource.aiScheduler, // AI 管家创建
          conversationId: conversation.id,
          contextLastUserMessageId: lastUserMsgId,
          contextLastUserMessageAt: lastUserMsgAt,
          contextSnapshot: contextSnapshot,
        );

        // 2. 注册后台 WorkManager 任务 (仅当 API Key 存在时)
        if (apiKey != null && apiKey.isNotEmpty) {
          await BackgroundService.scheduleOneOffTask(
            uniqueName: 'trigger_${createdTrigger.id}',
            delay: Duration(minutes: minutes),
            inputData: {
              'triggerId': createdTrigger.id,
              'apiKey': apiKey,
              'apiBase': apiBase,
              'model': model,
              'prompt': prompt, // AI 生成的 System Prompt
              'contextSnapshot': contextSnapshot,
              'convId': conversation.id,
              'userTitle': conversation.addressUser ?? 'User',
              'characterName': conversation.title,
            },
          );
          AppLogger.info('ContextAnalyzer', 'Scheduled background task',
              metadata: {'delay': minutes});
        }

        AppLogger.info('ContextAnalyzer', 'Scheduled trigger', metadata: {
          'triggerId': createdTrigger.id,
          'title': title,
          'minutes': minutes,
          'source': 'aiScheduler'
        });
      }
    } catch (e) {
      AppLogger.warning('ContextAnalyzer', 'Failed to parse scheduler JSON',
          metadata: {'json': jsonStr, 'error': e.toString()});
    }
  }
}
