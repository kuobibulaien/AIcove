import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../background_agent/background_agent_service.dart';
import '../../background_agent/domain/background_agent_definition.dart';
import '../../background_agent/domain/background_context_spec.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../chat/services/chat_history_store.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/time_awareness/time_awareness_plugin.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'conversation_proactive_state.dart';
import 'proactive_scheduler_tools.dart';

final contextAnalyzerProvider = Provider((ref) => ContextAnalyzer(ref));

class ContextAnalyzer {
  ContextAnalyzer(this._ref, {BackgroundAgentService? backgroundAgentService})
      : _backgroundAgentService = backgroundAgentService;

  final Ref _ref;
  final BackgroundAgentService? _backgroundAgentService;
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

  BackgroundAgentService get _agentService =>
      _backgroundAgentService ?? _ref.read(backgroundAgentServiceProvider);

  Future<void> _appendHistoryLog({
    required AutoReplyTriggerLogCategory category,
    required String event,
    required String message,
    String? conversationId,
    TriggerSource? source,
    bool? success,
    AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'context_analyzer_${DateTime.now().microsecondsSinceEpoch}',
        category: category,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        conversationId: conversationId,
        source: source,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  }

  Future<ContextAnalysisDecision?> analyze(
    Conversation conversation, {
    required ConversationProactiveState proactiveState,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final autoReplySettings = settings.autoReplySettings;

    final recent =
        await _ref.read(chatHistoryStoreProvider).loadCanonicalContextMessages(
              conversation.id,
              limit: 10,
            );
    if (recent.isEmpty) {
      return null;
    }

    final pluginManager = _ref.read(pluginManagerProvider);
    final timeAwarenessPlugin =
        pluginManager.getPlugin('time_awareness') as TimeAwarenessPlugin?;
    final includeTimestamp =
        timeAwarenessPlugin?.shouldIncludeTimestamp ?? false;

    final analyzerPromptTemplate =
        autoReplySettings.analyzerPrompt.trim().isNotEmpty
            ? _resolveAnalyzerPromptTemplate(autoReplySettings.analyzerPrompt)
            : PromptBuiltinDefaults.requireTemplate(
                'auto_reply.analyzer.default',
              );
    final analyzerPrompt = await _buildAnalyzerPrompt(
      template: analyzerPromptTemplate,
      conversation: conversation,
      proactiveState: proactiveState,
    );

    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.agent,
      event: 'analyzer_agent_started',
      message: '后台 Agent 开始分析主动回复策略',
      conversationId: conversation.id,
      metadata: {
        'recentMessageCount': recent.length,
        'includeTimestamp': includeTimestamp,
      },
    );

    final schedulerToolbox = ProactiveSchedulerToolbox(
      ref: _ref,
      conversation: conversation,
      contextMessages: recent,
    );

    final result = await _agentService.run(
      definition: BackgroundAgentDefinition(
        id: 'auto_reply_scheduler',
        name: '主动回复触发判断',
        objectivePrompt: analyzerPrompt,
        contextSpec: BackgroundContextSpec(
          lastMessages: recent.length,
          includeUser: true,
          includeAssistant: true,
          includeSystem: false,
          includeTimestamps: includeTimestamp,
        ),
        modelRef: _resolveAnalyzerModelRef(settings, autoReplySettings),
        temperature: 0.2,
        maxRounds: 4,
      ),
      conversationId: conversation.id,
      contextMessages: recent,
      additionalTools: schedulerToolbox.tools,
    );

    final toolCreatedTriggerId = schedulerToolbox.createdTriggerId;
    final decision = toolCreatedTriggerId == null
        ? _parseDecision(
            jsonStr: result.text,
            recentMessages: recent,
          )
        : ContextAnalysisDecision(
            contextMessages: recent,
            createdTriggerId: toolCreatedTriggerId,
          );
    if (decision == null) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.agent,
        event: 'analyzer_agent_invalid_result',
        message: '后台 Agent 已返回结果，但无法解析为主动回复决策',
        conversationId: conversation.id,
        level: AutoReplyTriggerLogLevel.warning,
        success: false,
        metadata: {
          'resultPreview': _truncateForLog(result.text),
        },
      );
      AppLogger.warning(
        'ContextAnalyzer',
        'Failed to parse analyzer decision',
        metadata: {'conversationId': conversation.id, 'raw': result.text},
      );
    } else {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.agent,
        event: 'analyzer_agent_finished',
        message: '后台 Agent 已完成主动回复策略分析',
        conversationId: conversation.id,
        success: true,
        metadata: {
          'hasSessionPatch': decision.sessionPatch != null,
          'hasTriggerPlan': decision.triggerPlan != null,
          'resultPreview': _truncateForLog(result.text),
        },
      );
    }
    return decision;
  }

  String _truncateForLog(String value, {int maxLength = 180}) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength)}…';
  }

  String _resolveAnalyzerModelRef(
    AppSettings settings,
    AutoReplySettings autoReplySettings,
  ) {
    final analyzerModel = autoReplySettings.analyzerModel?.trim();
    if (analyzerModel == null || analyzerModel.isEmpty) {
      return settings.defaultModelName;
    }

    final analyzerProvider = autoReplySettings.analyzerProvider?.trim();
    if (analyzerProvider != null &&
        analyzerProvider.isNotEmpty &&
        !analyzerModel.contains(':')) {
      return settings.buildModelRef(analyzerProvider, analyzerModel);
    }
    return analyzerModel;
  }

  String _resolveAnalyzerPromptTemplate(String storedPrompt) {
    if (storedPrompt.trim() == AutoReplySettings.defaultAnalyzerPrompt.trim()) {
      return PromptBuiltinDefaults.requireTemplate(
        'auto_reply.analyzer.default',
      );
    }
    return storedPrompt;
  }

  Future<String> _buildAnalyzerPrompt({
    required String template,
    required Conversation conversation,
    required ConversationProactiveState proactiveState,
  }) async {
    final currentRolePersona =
        PersonaPromptCodec.parse(conversation.personaPrompt).userPrompt.trim();
    final triggerSummaries =
        await _loadConversationTriggerSummaries(conversation.id);
    return PromptTemplateRenderer.renderTrimmed(
      template,
      <String, Object?>{
        'current_role_persona': currentRolePersona,
        'trigger_list': _formatTriggerListForPrompt(triggerSummaries),
        'state_json': _buildRuntimeStateJson(
          conversation: conversation,
          proactiveState: proactiveState,
          currentRolePersona: currentRolePersona,
          triggerSummaries: triggerSummaries,
        ),
      },
    );
  }

  Future<List<Map<String, Object?>>> _loadConversationTriggerSummaries(
    String conversationId,
  ) async {
    try {
      final triggers = await _historyStorage.loadTriggers();
      final filtered = triggers.where((trigger) {
        if (trigger.conversationId != conversationId) {
          return false;
        }
        return trigger.isActive ||
            trigger.status == AutoReplyTriggerStatus.paused;
      }).toList();
      filtered.sort((a, b) {
        final fireAtComparison = a.nextFireAt.compareTo(b.nextFireAt);
        if (fireAtComparison != 0) {
          return fireAtComparison;
        }
        return a.createdAt.compareTo(b.createdAt);
      });
      return filtered
          .take(8)
          .map(_triggerSummaryForAnalyzer)
          .toList(growable: false);
    } catch (e) {
      AppLogger.warning(
        'ContextAnalyzer',
        '加载当前会话触发器摘要失败',
        metadata: {
          'conversationId': conversationId,
          'error': e.toString(),
        },
      );
      return const <Map<String, Object?>>[];
    }
  }

  Map<String, Object?> _triggerSummaryForAnalyzer(AutoReplyTrigger trigger) {
    final summary = <String, Object?>{
      'id': _truncateForStateJson(trigger.id, maxLength: 80),
      'title': _truncateForStateJson(trigger.title, maxLength: 80),
      'status': trigger.status.name,
      'source': trigger.source.name,
      'priority': trigger.priority.name,
      'next_fire_at': trigger.nextFireAt.toIso8601String(),
      'delay_minutes': trigger.delayMinutes,
      'allow_night': trigger.allowNight,
      'require_exact': trigger.requireExact,
      'manual': trigger.manual,
      'system_reminder':
          _truncateForStateJson(trigger.prompt ?? '', maxLength: 220),
    };
    summary.removeWhere((_, value) {
      return value == null || (value is String && value.trim().isEmpty);
    });
    return summary;
  }

  String _formatTriggerListForPrompt(
    List<Map<String, Object?>> triggerSummaries,
  ) {
    if (triggerSummaries.isEmpty) {
      return '当前会话暂无待处理触发器。';
    }
    return triggerSummaries.map((summary) {
      final fields = <String>[
        'id=${summary['id']}',
        'title=${summary['title']}',
        'status=${summary['status']}',
        'next_fire_at=${summary['next_fire_at']}',
        'priority=${summary['priority']}',
        'source=${summary['source']}',
        'allow_night=${summary['allow_night']}',
        'manual=${summary['manual']}',
      ];
      final reminder = (summary['system_reminder']?.toString() ?? '').trim();
      if (reminder.isNotEmpty) {
        fields.add('system_reminder=$reminder');
      }
      return '- ${fields.join(' | ')}';
    }).join('\n');
  }

  String _buildRuntimeStateJson({
    required Conversation conversation,
    required ConversationProactiveState proactiveState,
    required String currentRolePersona,
    required List<Map<String, Object?>> triggerSummaries,
  }) {
    final now = DateTime.now();
    return jsonEncode({
      'conversation_id': conversation.id,
      'current_role_persona': _truncateForStateJson(currentRolePersona),
      'trigger_list': triggerSummaries,
      'device_local_time': now.toIso8601String(),
      'device_timezone_name': now.timeZoneName,
      'device_timezone_offset': _formatTimezoneOffset(now.timeZoneOffset),
      'mode': proactiveState.mode.name,
      'unreplied_count': proactiveState.unrepliedCount,
      'last_user_message_id': proactiveState.lastUserMessageId,
      'last_user_at': proactiveState.lastUserAt?.toIso8601String(),
      'last_proactive_at': proactiveState.lastProactiveAt?.toIso8601String(),
      'silence_until': proactiveState.silenceUntil?.toIso8601String(),
      'pending_auto_trigger_id': proactiveState.pendingAutoTriggerId,
    });
  }

  String _truncateForStateJson(String value, {int maxLength = 600}) {
    final normalized = value.trim();
    if (normalized.length <= maxLength) {
      return normalized;
    }
    return '${normalized.substring(0, maxLength)}…';
  }

  String _formatTimezoneOffset(Duration offset) {
    final totalMinutes = offset.inMinutes;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absoluteMinutes = totalMinutes.abs();
    final hours = (absoluteMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absoluteMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hours:$minutes';
  }

  ContextAnalysisDecision? _parseDecision({
    required String jsonStr,
    required List<Message> recentMessages,
  }) {
    try {
      final clean = _stripCodeFence(jsonStr);
      final decoded = jsonDecode(clean);

      if (decoded is List) {
        return _parseLegacyTriggerList(
          decoded,
          recentMessages: recentMessages,
        );
      }

      if (decoded is! Map) {
        return null;
      }

      final data = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      if (data.containsKey('decision')) {
        return _parseSingleDecisionObject(
          data,
          recentMessages: recentMessages,
        );
      }

      final sessionPatch = _parseSessionPatch(data['session_patch']);
      final triggerPlan = _parseTriggerPlan(data['trigger_ops']);
      if (sessionPatch == null && triggerPlan == null) {
        return null;
      }

      return ContextAnalysisDecision(
        contextMessages: recentMessages,
        sessionPatch: sessionPatch,
        triggerPlan: triggerPlan,
      );
    } catch (e) {
      AppLogger.warning(
        'ContextAnalyzer',
        'Analyzer JSON decode failed',
        metadata: {'error': e.toString(), 'raw': jsonStr},
      );
      return null;
    }
  }

  String _stripCodeFence(String jsonStr) {
    var clean = jsonStr.trim();
    if (clean.startsWith('```json')) {
      clean = clean.substring(7);
    } else if (clean.startsWith('```')) {
      clean = clean.substring(3);
    }
    if (clean.endsWith('```')) {
      clean = clean.substring(0, clean.length - 3);
    }
    return clean.trim();
  }

  ContextAnalysisDecision? _parseSingleDecisionObject(
    Map<String, dynamic> data, {
    required List<Message> recentMessages,
  }) {
    final decision = (data['decision'] as String?)?.trim().toLowerCase() ?? '';
    if (decision.isEmpty) {
      return null;
    }

    if (decision == 'silent' || decision == 'stay_silent') {
      final delayMinutes = _parsePositiveInt(data['delay_minutes']) ?? 480;
      return ContextAnalysisDecision(
        contextMessages: recentMessages,
        sessionPatch: ContextAnalysisSessionPatch(
          mode: ConversationProactiveMode.silent,
          silenceDuration: Duration(minutes: delayMinutes),
          reason: (data['reason'] as String?)?.trim(),
        ),
      );
    }

    final triggerPlan = _parseTriggerPlan(<Map<String, dynamic>>[
      <String, dynamic>{
        'op': 'replace',
        'kind': decision,
        'title': data['title'],
        'delay_minutes': data['delay_minutes'],
        'allow_night': data['allow_night'],
        'priority': data['priority'],
        'system_reminder': data['system_reminder'] ?? data['prompt'],
      },
    ]);
    if (triggerPlan == null) {
      return null;
    }

    return ContextAnalysisDecision(
      contextMessages: recentMessages,
      triggerPlan: triggerPlan,
    );
  }

  ContextAnalysisDecision? _parseLegacyTriggerList(
    List<dynamic> rawList, {
    required List<Message> recentMessages,
  }) {
    final items = rawList
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .toList(growable: false);
    if (items.isEmpty) {
      return ContextAnalysisDecision(
        contextMessages: recentMessages,
        sessionPatch: const ContextAnalysisSessionPatch(
          mode: ConversationProactiveMode.silent,
          silenceDuration: Duration(hours: 8),
          reason: 'legacy_empty_result',
        ),
      );
    }

    final first = items.first;
    final delayMinutes = _parsePositiveInt(first['delay_minutes']) ?? 60;
    final triggerPlan = ContextAnalysisTriggerPlan(
      kind: _inferLegacyKind(delayMinutes),
      title: ((first['title'] as String?)?.trim().isNotEmpty ?? false)
          ? (first['title'] as String).trim()
          : _defaultTitleForKind(_inferLegacyKind(delayMinutes)),
      delayMinutes: delayMinutes,
      allowNight: first['allow_night'] == true,
      priority: _parsePriority(first['priority']) ??
          _defaultPriorityForKind(_inferLegacyKind(delayMinutes)),
      systemReminder: ((first['prompt'] as String?)?.trim().isNotEmpty ?? false)
          ? (first['prompt'] as String).trim()
          : _defaultSystemReminderForKind(_inferLegacyKind(delayMinutes)),
    );

    return ContextAnalysisDecision(
      contextMessages: recentMessages,
      triggerPlan: triggerPlan,
    );
  }

  ContextAnalysisSessionPatch? _parseSessionPatch(dynamic rawPatch) {
    if (rawPatch is! Map) {
      return null;
    }

    final patch = Map<String, dynamic>.from(rawPatch.cast<String, dynamic>());
    final mode = _parseMode(patch['mode'] as String?);
    if (mode == null) {
      return null;
    }

    final silenceMinutes = _parsePositiveInt(patch['silence_minutes']);
    return ContextAnalysisSessionPatch(
      mode: mode,
      silenceDuration: mode == ConversationProactiveMode.silent
          ? Duration(minutes: silenceMinutes ?? 480)
          : null,
      reason: (patch['reason'] as String?)?.trim(),
    );
  }

  ContextAnalysisTriggerPlan? _parseTriggerPlan(dynamic rawOps) {
    final candidates = <Map<String, dynamic>>[];
    if (rawOps is List) {
      for (final item in rawOps) {
        if (item is! Map) continue;
        candidates.add(Map<String, dynamic>.from(item.cast<String, dynamic>()));
      }
    } else if (rawOps is Map) {
      candidates.add(Map<String, dynamic>.from(rawOps.cast<String, dynamic>()));
    } else {
      return null;
    }

    for (final candidate in candidates) {
      final op =
          (candidate['op'] as String?)?.trim().toLowerCase() ?? 'replace';
      if (op == 'delete' || op == 'remove' || op == 'clear') {
        continue;
      }

      final kind = _parseTriggerKind(candidate['kind'] as String?);
      if (kind == null) {
        continue;
      }

      final systemReminder =
          (candidate['system_reminder'] as String?)?.trim() ??
              (candidate['prompt'] as String?)?.trim() ??
              '';

      if (systemReminder.isEmpty) {
        continue;
      }

      final delayMinutes = _parsePositiveInt(candidate['delay_minutes']) ??
          _defaultDelayForKind(kind);

      return ContextAnalysisTriggerPlan(
        kind: kind,
        title: ((candidate['title'] as String?)?.trim().isNotEmpty ?? false)
            ? (candidate['title'] as String).trim()
            : _defaultTitleForKind(kind),
        delayMinutes: delayMinutes,
        allowNight: candidate['allow_night'] == true,
        priority: _parsePriority(candidate['priority']) ??
            _defaultPriorityForKind(kind),
        systemReminder: systemReminder,
      );
    }

    return null;
  }

  ConversationProactiveMode? _parseMode(String? rawMode) {
    switch (rawMode?.trim().toLowerCase()) {
      case 'active':
        return ConversationProactiveMode.active;
      case 'silent':
        return ConversationProactiveMode.silent;
      case 'dormant':
        return ConversationProactiveMode.dormant;
      default:
        return null;
    }
  }

  ContextAnalysisTriggerKind? _parseTriggerKind(String? rawKind) {
    switch (rawKind?.trim().toLowerCase()) {
      case 'continue_chat':
      case 'continuechat':
      case 'comforting':
        return ContextAnalysisTriggerKind.continueChat;
      case 'check_in':
      case 'checkin':
        return ContextAnalysisTriggerKind.checkIn;
      case 'new_topic':
      case 'newtopic':
        return ContextAnalysisTriggerKind.newTopic;
      case 'silent':
      case 'stay_silent':
      case 'staysilent':
        return null;
      default:
        return null;
    }
  }

  int? _parsePositiveInt(dynamic rawValue) {
    if (rawValue is num) {
      final value = rawValue.toInt();
      return value > 0 ? value : null;
    }
    if (rawValue is String) {
      final value = int.tryParse(rawValue.trim());
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  AutoReplyTriggerPriority? _parsePriority(dynamic rawPriority) {
    final value = rawPriority?.toString().trim().toLowerCase();
    switch (value) {
      case 'high':
        return AutoReplyTriggerPriority.high;
      case 'low':
        return AutoReplyTriggerPriority.low;
      case 'medium':
        return AutoReplyTriggerPriority.medium;
      default:
        return null;
    }
  }

  ContextAnalysisTriggerKind _inferLegacyKind(int delayMinutes) {
    if (delayMinutes <= 5) {
      return ContextAnalysisTriggerKind.continueChat;
    }
    if (delayMinutes <= 120) {
      return ContextAnalysisTriggerKind.checkIn;
    }
    return ContextAnalysisTriggerKind.newTopic;
  }

  int _defaultDelayForKind(ContextAnalysisTriggerKind kind) {
    switch (kind) {
      case ContextAnalysisTriggerKind.continueChat:
        return 1;
      case ContextAnalysisTriggerKind.checkIn:
        return 30;
      case ContextAnalysisTriggerKind.newTopic:
        return 480;
    }
  }

  String _defaultTitleForKind(ContextAnalysisTriggerKind kind) {
    switch (kind) {
      case ContextAnalysisTriggerKind.continueChat:
        return '继续当前话题';
      case ContextAnalysisTriggerKind.checkIn:
        return '稍后问候';
      case ContextAnalysisTriggerKind.newTopic:
        return '晚些时候开启新话题';
    }
  }

  String _defaultSystemReminderForKind(ContextAnalysisTriggerKind kind) {
    switch (kind) {
      case ContextAnalysisTriggerKind.continueChat:
        return '刚才的话题还没有自然收束，用户安静了几分钟，现在补一个轻量顺接。';
      case ContextAnalysisTriggerKind.checkIn:
        return '用户前面提到去处理某件事，现在到了一个合适的回访时间，可以轻问一句近况。';
      case ContextAnalysisTriggerKind.newTopic:
        return '距离上一轮对话已经过去较久，可以用轻松的新话题重新开启交流。';
    }
  }

  AutoReplyTriggerPriority _defaultPriorityForKind(
    ContextAnalysisTriggerKind kind,
  ) {
    switch (kind) {
      case ContextAnalysisTriggerKind.continueChat:
        return AutoReplyTriggerPriority.medium;
      case ContextAnalysisTriggerKind.checkIn:
        return AutoReplyTriggerPriority.medium;
      case ContextAnalysisTriggerKind.newTopic:
        return AutoReplyTriggerPriority.low;
    }
  }
}

class ContextAnalysisDecision {
  const ContextAnalysisDecision({
    required this.contextMessages,
    this.sessionPatch,
    this.triggerPlan,
    this.createdTriggerId,
  });

  final List<Message> contextMessages;
  final ContextAnalysisSessionPatch? sessionPatch;
  final ContextAnalysisTriggerPlan? triggerPlan;
  final String? createdTriggerId;
}

class ContextAnalysisSessionPatch {
  const ContextAnalysisSessionPatch({
    required this.mode,
    this.silenceDuration,
    this.reason,
  });

  final ConversationProactiveMode mode;
  final Duration? silenceDuration;
  final String? reason;
}

enum ContextAnalysisTriggerKind {
  continueChat,
  checkIn,
  newTopic,
}

class ContextAnalysisTriggerPlan {
  const ContextAnalysisTriggerPlan({
    required this.kind,
    required this.title,
    required this.delayMinutes,
    required this.allowNight,
    required this.priority,
    required this.systemReminder,
  });

  final ContextAnalysisTriggerKind kind;
  final String title;
  final int delayMinutes;
  final bool allowNight;
  final AutoReplyTriggerPriority priority;
  final String systemReminder;
}
