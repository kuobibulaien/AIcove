// ignore_for_file: avoid_print
// 注意：此文件在后台 isolate 中运行，无法使用 AppLogger（依赖 Flutter framework）。
// 这里的 print 语句仅用于后台调试，在 release 模式下不会输出。
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/api/providers/provider_chat_api_path.dart';
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database.dart' hide MessageBlock;
import '../../../core/database/repositories/repositories.dart';
import '../../../core/models/message_block.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../../core/services/system_reminder_service.dart';
import '../../chat/domain/message.dart' as chat;
import '../../chat/domain/conversation_context_window.dart';
import '../../chat/domain/persona_prompt_codec.dart';
import '../../chat/services/chat_message_processor.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../plugins/image/image_plugin.dart' show ImagePlugin;
import '../../plugins/plugin_content_tags.dart';
import '../../chat/services/chat_message_projection_codec.dart';
import '../../chat/services/chat_types.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_agent_helpers.dart';
import 'auto_reply_claim_store.dart';
import 'auto_reply_request_config.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'conversation_proactive_state.dart';
import 'conversation_proactive_state_storage.dart';

// 任务名称常量
const String taskNameActiveReply = 'com.aicove.active_reply';
const String _uiModelsStoreKey = 'aicove.ui_models.v1';
const String _triggerStoreKey = 'aicove.auto_triggers.v1';
final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();
const SystemReminderService _systemReminderService = SystemReminderService();

@visibleForTesting
class BackgroundAssistantStoragePayload {
  const BackgroundAssistantStoragePayload({
    required this.rawText,
    required this.displayText,
    required this.rawPayload,
  });

  final String rawText;
  final String displayText;
  final Map<String, dynamic> rawPayload;
}

@visibleForTesting
BackgroundAssistantStoragePayload buildBackgroundAssistantStoragePayload(
  String reply,
) {
  final rawText = reply.trim();
  final processedText = chatMessageProcessor.stripPluginTags(rawText).trim();
  final displayText = _resolveBackgroundDisplayText(
    rawText: rawText,
    processedText: processedText,
  );
  final payloadProcessedText =
      processedText.isNotEmpty ? processedText : displayText;
  final rawPayload = ChatMessageProjectionCodec.buildRawAssistantPayload(
    apiResult: ApiCallResult(
      rawReplyText: rawText,
      replyText: rawText,
      processedText: payloadProcessedText,
      pluginEvents: const [],
      toolResults: const [],
    ),
  );
  return BackgroundAssistantStoragePayload(
    rawText: rawText,
    displayText: displayText,
    rawPayload: rawPayload,
  );
}

@visibleForTesting
bool shouldSkipBackgroundActiveReplyForMissingModelConfig({
  required String apiKey,
  required String? cachedReply,
}) {
  return apiKey.trim().isEmpty && (cachedReply?.trim().isEmpty ?? true);
}

/// 后台即时生成的系统提示词：角色人设 + 当前时间 + 后台纯文本输出约束。
/// 模板来自 prompt defaults 节点 `auto_reply.background.objective`。
@visibleForTesting
String buildBackgroundLiveGenerationSystemPrompt({
  required String characterName,
  required String userTitle,
  required String personaUserPrompt,
  required DateTime now,
}) {
  final objective = PromptTemplateRenderer.renderTrimmed(
    PromptBuiltinDefaults.requireTemplate('auto_reply.background.objective'),
    <String, Object?>{
      'assistant_name': characterName,
      'user_name': userTitle,
      'current_role_persona': personaUserPrompt,
      'datetime': _formatBackgroundLocalTime(now),
    },
    collapseExtraBlankLines: true,
  );
  final semantics = _systemReminderService.buildReminderSemanticsPrompt();
  return [objective, semantics]
      .where((section) => section.trim().isNotEmpty)
      .join('\n\n');
}

String _formatBackgroundLocalTime(DateTime now) {
  String pad(int value) => value.toString().padLeft(2, '0');
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absOffset = offset.abs();
  final offsetText =
      '$sign${pad(absOffset.inHours)}:${pad(absOffset.inMinutes % 60)}';
  return '${now.year}-${pad(now.month)}-${pad(now.day)} '
      '${pad(now.hour)}:${pad(now.minute)} (UTC$offsetText)';
}

Future<String> _loadConversationPersonaUserPrompt(String conversationId) async {
  final db = AppDatabase();
  try {
    final convRepo = ConversationRepository(db);
    final conversation = await convRepo.getById(conversationId);
    final raw = conversation?.personaPrompt ?? '';
    return PersonaPromptCodec.parse(raw).userPrompt.trim();
  } catch (e) {
    print('[Background] Failed to load conversation persona: $e');
    return '';
  } finally {
    await db.close();
  }
}

/// 后台发送门禁结果：reason 记录拦截原因，retryDelay 表示可在多久后重试。
@visibleForTesting
class BackgroundSendGateResult {
  const BackgroundSendGateResult({required this.reason, this.retryDelay});

  final String reason;
  final Duration? retryDelay;
}

@visibleForTesting
bool isWithinQuietHoursWindow(
  DateTime now, {
  required String start,
  required String end,
}) {
  int parseMinutes(String value, int fallbackHour, int fallbackMinute) {
    final parts = value.split(':');
    if (parts.length != 2) return fallbackHour * 60 + fallbackMinute;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return fallbackHour * 60 + fallbackMinute;
    }
    return hour.clamp(0, 23).toInt() * 60 + minute.clamp(0, 59).toInt();
  }

  final nowMinutes = now.hour * 60 + now.minute;
  final startMinutes = parseMinutes(start, 22, 0);
  final endMinutes = parseMinutes(end, 8, 0);

  if (startMinutes == endMinutes) return false;
  if (startMinutes < endMinutes) {
    return nowMinutes >= startMinutes && nowMinutes < endMinutes;
  }
  return nowMinutes >= startMinutes || nowMinutes < endMinutes;
}

@visibleForTesting
Duration delayUntilQuietHoursEnd(DateTime now, String end) {
  final parts = end.split(':');
  final hour = parts.length == 2 ? int.tryParse(parts[0]) ?? 8 : 8;
  final minute = parts.length == 2 ? int.tryParse(parts[1]) ?? 0 : 0;
  var candidate = DateTime(now.year, now.month, now.day, hour, minute);
  if (!candidate.isAfter(now)) {
    candidate = candidate.add(const Duration(days: 1));
  }
  return candidate.difference(now) + const Duration(minutes: 1);
}

/// 与前台 `_pollDueTriggers()` 同源的发送门禁：quiet hours / dailyLimit / minInterval。
/// 返回 null 表示放行。
@visibleForTesting
BackgroundSendGateResult? evaluateBackgroundSendGates({
  required DateTime now,
  required Map<String, dynamic> autoReplySettings,
  required bool triggerAllowNight,
  required List<Map<String, dynamic>> allTriggers,
}) {
  final quietEnabled = autoReplySettings['quiet_hours_enabled'] != false;
  final quietStart =
      (autoReplySettings['quiet_hours_start'] as String?) ?? '22:00';
  final quietEnd = (autoReplySettings['quiet_hours_end'] as String?) ?? '08:00';
  if (quietEnabled &&
      !triggerAllowNight &&
      isWithinQuietHoursWindow(now, start: quietStart, end: quietEnd)) {
    return BackgroundSendGateResult(
      reason: 'quiet_hours',
      retryDelay: delayUntilQuietHoursEnd(now, quietEnd),
    );
  }

  DateTime? parseFiredAt(Map<String, dynamic> trigger) {
    if ((trigger['status'] as String?) != 'fired') return null;
    final raw = trigger['last_fired_at'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  final firedTimes = allTriggers
      .map(parseFiredAt)
      .whereType<DateTime>()
      .toList(growable: false);

  final dailyLimit = (autoReplySettings['daily_limit'] as num?)?.toInt() ?? 3;
  final firedToday = firedTimes
      .where((t) =>
          t.year == now.year && t.month == now.month && t.day == now.day)
      .length;
  if (firedToday >= dailyLimit) {
    final nextMidnight = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1, minutes: 1));
    return BackgroundSendGateResult(
      reason: 'daily_limit',
      retryDelay: nextMidnight.difference(now),
    );
  }

  final minIntervalMinutes =
      (autoReplySettings['min_interval_minutes'] as num?)?.toInt() ?? 120;
  if (minIntervalMinutes > 0 && firedTimes.isNotEmpty) {
    final latest = firedTimes.reduce((a, b) => a.isAfter(b) ? a : b);
    final elapsed = now.difference(latest);
    final required = Duration(minutes: minIntervalMinutes);
    if (elapsed < required) {
      return BackgroundSendGateResult(
        reason: 'min_interval',
        retryDelay: required - elapsed + const Duration(minutes: 1),
      );
    }
  }

  return null;
}

Future<Map<String, dynamic>> _loadAutoReplySettingsMap() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_uiModelsStoreKey);
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    final data = jsonDecode(raw);
    if (data is! Map) return const <String, dynamic>{};
    final settings = data['auto_reply_settings'];
    if (settings is! Map) return const <String, dynamic>{};
    return Map<String, dynamic>.from(settings.cast<String, dynamic>());
  } catch (e) {
    print('[Background] Failed to read auto-reply settings map: $e');
    return const <String, dynamic>{};
  }
}

/// 执行时现读模型请求配置（默认聊天模型 + 供应商 + 直连兜底）。
/// 返回 null 表示设置不可读，调用方回退旧任务携带的配置快照。
Future<AutoReplyRequestConfig?> _loadBackgroundRequestConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_uiModelsStoreKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final settings = mapUiModelsToAppSettings(
      Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
    );
    return await resolveAutoReplyRequestConfig(settings);
  } catch (e) {
    print('[Background] Failed to resolve request config: $e');
    return null;
  }
}

Future<List<Map<String, dynamic>>> _loadAllTriggerMaps() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <Map<String, dynamic>>[];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<String, dynamic>()))
        .toList(growable: false);
  } catch (e) {
    print('[Background] Failed to load trigger list: $e');
    return const <Map<String, dynamic>>[];
  }
}

Future<void> _rescheduleBackgroundTask({
  required String triggerId,
  required Map<String, dynamic> data,
  required Duration delay,
}) async {
  final normalizedDelay =
      delay < const Duration(minutes: 1) ? const Duration(minutes: 1) : delay;
  await Workmanager().registerOneOffTask(
    'trigger_$triggerId',
    taskNameActiveReply,
    initialDelay: normalizedDelay,
    inputData: data,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

/// 后台尝试认领触发器执行权；失败返回 false（前台已在执行）。
/// 数据库异常时按「保唯一性」原则返回 false，由前台补发。
Future<bool> _tryClaimTriggerExecution(String triggerId) async {
  final db = AppDatabase();
  try {
    return await AutoReplyClaimStore(db).tryClaim(
      triggerId: triggerId,
      claimedBy: AutoReplyClaimOwner.background,
    );
  } catch (e) {
    print('[Background] Failed to claim trigger execution: $e');
    return false;
  } finally {
    await db.close();
  }
}

/// 后台发送失败后释放执行权，让前台/重试可以重新认领。
Future<void> _releaseTriggerExecutionClaim(String triggerId) async {
  final db = AppDatabase();
  try {
    await AutoReplyClaimStore(db).release(triggerId);
  } catch (e) {
    print('[Background] Failed to release trigger claim: $e');
  } finally {
    await db.close();
  }
}

String _resolveBackgroundDisplayText({
  required String rawText,
  required String processedText,
}) {
  if (processedText.isNotEmpty) {
    return processedText;
  }
  if (firstPartyContentTagScanner.scan(rawText).any(
    (segment) =>
        segment is ContentTagElement &&
        segment.closed &&
        ImagePlugin.isInlineImageElement(segment),
  )) {
    return '[图片]';
  }
  return rawText;
}

Future<void> _appendHistoryLog({
  required String event,
  required String message,
  String? triggerId,
  String? title,
  String? conversationId,
  TriggerSource? source,
  bool? success,
  AutoReplyTriggerLogCategory category = AutoReplyTriggerLogCategory.background,
  AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
  Map<String, dynamic> metadata = const <String, dynamic>{},
}) async {
  try {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'background_${DateTime.now().microsecondsSinceEpoch}',
        category: category,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        triggerId: triggerId,
        title: title,
        conversationId: conversationId,
        source: source,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  } catch (e) {
    print('[Background] Failed to append history log: $e');
  }
}

// 入口函数（必须是顶层函数）
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();

    if (task == taskNameActiveReply && inputData != null) {
      print('[Background] Active Reply Task Started');
      try {
        await _handleActiveReplyTask(inputData);
      } catch (e) {
        print('[Background] Error: $e');
        return Future.value(false);
      }
    }
    return Future.value(true);
  });
}

// 具体的任务逻辑
Future<void> _handleActiveReplyTask(Map<String, dynamic> data) async {
  final String triggerId = data['triggerId'] ?? '';
  final String prompt = data['prompt'] ?? '';
  final String? contextSnapshot = data['contextSnapshot'] as String?;
  final String convId = data['convId'] ?? '';
  final String characterName = data['characterName'] ?? 'AIcove';
  final String userTitle = data['userTitle'] ?? 'User';
  final triggerTitle = await _loadTriggerTitle(triggerId, convId);

  // 模型配置不随任务快照：执行时现读最新设置（换 key/换模型立即生效，
  // 密钥不落地 WorkManager）。旧版任务 inputData 中的配置仅作升级期兜底。
  final requestConfig = await _loadBackgroundRequestConfig();
  final String apiKey;
  final String apiBase;
  final String model;
  final String requestFormat;
  final String apiPath;
  final bool vertexExpress;
  if (requestConfig != null) {
    apiKey = requestConfig.providerApiKey ?? '';
    apiBase = requestConfig.providerApiBase;
    model = requestConfig.modelFullId;
    requestFormat =
        requestConfig.customConfig['requestFormat']?.toString().trim() ?? '';
    apiPath = requestConfig.customConfig['apiPath']?.toString().trim() ?? '';
    vertexExpress = requestConfig.customConfig['vertexExpress'] == true;
  } else {
    apiKey = data['apiKey'] ?? '';
    apiBase = data['apiBase'] ?? '';
    model = data['model'] ?? '';
    requestFormat = data['requestFormat'] ?? '';
    apiPath = data['apiPath'] ?? '';
    vertexExpress = data['vertexExpress'] == true;
  }

  await _appendHistoryLog(
    event: 'task_started',
    message: 'WorkManager 已开始执行后台主动回复任务',
    triggerId: triggerId.isEmpty ? null : triggerId,
    title: triggerTitle,
    conversationId: convId.isEmpty ? null : convId,
    metadata: {
      'hasContextSnapshot': contextSnapshot?.trim().isNotEmpty == true,
      'model': model,
    },
  );

  if (convId.isEmpty) {
    print('[Background] Missing config, aborting.');
    await _appendHistoryLog(
      event: 'task_skipped_missing_config',
      message: '后台主动回复任务已跳过：缺少目标会话',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId.isEmpty ? null : convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return;
  }

  final autoReplyEnabled = await _isAutoReplyEnabled();
  if (!autoReplyEnabled) {
    print('[Background] Auto-reply disabled, skip task.');
    await _appendHistoryLog(
      event: 'task_skipped_auto_reply_disabled',
      message: '后台主动回复任务已跳过：总开关关闭',
      triggerId: triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return;
  }

  if (triggerId.isNotEmpty) {
    final active = await _isTriggerStillActive(triggerId, convId);
    if (!active) {
      print(
          '[Background] Trigger is no longer active, skip task. triggerId=$triggerId');
      await _appendHistoryLog(
        event: 'task_skipped_inactive_trigger',
        message: '后台主动回复任务已跳过：触发器已失效',
        triggerId: triggerId,
        title: triggerTitle,
        conversationId: convId,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return;
    }
  }

  // 与前台轮询同源的发送门禁：quiet hours / dailyLimit / minInterval。
  if (triggerId.isNotEmpty) {
    final allTriggers = await _loadAllTriggerMaps();
    final triggerMap = allTriggers
        .where((item) => (item['id'] as String?) == triggerId)
        .toList(growable: false);
    final triggerAllowNight =
        triggerMap.isNotEmpty && triggerMap.first['allow_night'] == true;
    final gate = evaluateBackgroundSendGates(
      now: DateTime.now(),
      autoReplySettings: await _loadAutoReplySettingsMap(),
      triggerAllowNight: triggerAllowNight,
      allTriggers: allTriggers,
    );
    if (gate != null) {
      var rescheduled = false;
      if (gate.retryDelay != null) {
        try {
          await _rescheduleBackgroundTask(
            triggerId: triggerId,
            data: data,
            delay: gate.retryDelay!,
          );
          rescheduled = true;
        } catch (e) {
          print('[Background] Failed to reschedule gated task: $e');
        }
      }
      print(
          '[Background] Send gated by ${gate.reason}, rescheduled=$rescheduled');
      await _appendHistoryLog(
        event: 'task_gated_${gate.reason}',
        message: rescheduled
            ? '后台主动回复命中发送门禁（${gate.reason}），已改期重试'
            : '后台主动回复命中发送门禁（${gate.reason}），等待前台补发',
        triggerId: triggerId,
        title: triggerTitle,
        conversationId: convId,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
        metadata: {
          'reason': gate.reason,
          'retryDelayMinutes': gate.retryDelay?.inMinutes,
          'rescheduled': rescheduled,
        },
      );
      return;
    }
  }

  // 执行权认领：与前台轮询链路互斥，认领失败说明前台已在执行
  if (triggerId.isNotEmpty) {
    final claimed = await _tryClaimTriggerExecution(triggerId);
    if (!claimed) {
      print(
          '[Background] Trigger already claimed elsewhere, skip. triggerId=$triggerId');
      await _appendHistoryLog(
        event: 'task_skipped_claim_lost',
        message: '后台主动回复任务已跳过：执行权已被前台链路认领',
        triggerId: triggerId,
        title: triggerTitle,
        conversationId: convId,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return;
    }
  }

  // 1. 读取预生成缓存：新鲜缓存直接发送；过期缓存降级为兜底文案
  final cached = triggerId.isEmpty
      ? null
      : await _loadCachedTriggerReply(triggerId, convId);
  final cachedReply = cached?.content;
  final cacheNow = DateTime.now();
  final cacheFresh = cached != null &&
      isCachedAutoReplyContentFresh(
        preparedAt: cached.preparedAt,
        now: cacheNow,
      );
  final cacheAgeMinutes = cached?.preparedAt == null
      ? null
      : cacheNow.difference(cached!.preparedAt!).inMinutes;
  var usedCachedReply = false;
  String? reply;
  if (cacheFresh) {
    reply = cachedReply;
    usedCachedReply = true;
    await _appendHistoryLog(
      event: 'task_used_cached_content',
      message: '后台任务命中新鲜 cachedContent，直接发送预生成文案',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      metadata: {
        'replyLength': reply!.length,
        'cacheAgeMinutes': cacheAgeMinutes,
      },
    );
  } else if (cachedReply != null && apiKey.trim().isEmpty) {
    // 没有模型配置无法即时生成：过期缓存仍优于不发
    reply = cachedReply;
    usedCachedReply = true;
    await _appendHistoryLog(
      event: 'task_used_stale_cached_content',
      message: '后台任务缺少模型配置，使用过期预生成文案兜底发送',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {
        'replyLength': reply.length,
        'cacheAgeMinutes': cacheAgeMinutes,
      },
    );
  } else if (cachedReply != null) {
    await _appendHistoryLog(
      event: 'task_cache_stale_live_generation',
      message: '预生成缓存已过期，后台任务优先即时生成，缓存降级为兜底',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      metadata: {
        'cacheAgeMinutes': cacheAgeMinutes,
      },
    );
  }

  if (shouldSkipBackgroundActiveReplyForMissingModelConfig(
    apiKey: apiKey,
    cachedReply: cachedReply,
  )) {
    print('[Background] Missing model config, aborting live generation.');
    await _appendHistoryLog(
      event: 'task_skipped_missing_model_config',
      message: '后台主动回复任务已跳过：无预生成内容且缺少模型配置',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    if (triggerId.isNotEmpty) {
      await _releaseTriggerExecutionClaim(triggerId);
    }
    return;
  }
  reply ??= await _fetchAiReply(
    apiKey,
    apiBase,
    model,
    prompt,
    conversationId: convId,
    characterName: characterName,
    userTitle: userTitle,
    requestFormat: requestFormat,
    apiPath: apiPath,
    vertexExpress: vertexExpress,
  );
  if (!usedCachedReply && reply != null && reply.isNotEmpty) {
    await _appendHistoryLog(
      event: 'task_generated_live_reply',
      message: '后台任务已即时生成主动回复文案',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      metadata: {
        'replyLength': reply.length,
      },
    );
  }
  if ((reply == null || reply.isEmpty) &&
      cachedReply != null &&
      cachedReply.isNotEmpty) {
    // 即时生成失败：回退过期缓存兜底
    reply = cachedReply;
    usedCachedReply = true;
    await _appendHistoryLog(
      event: 'task_fallback_cached_content',
      message: '后台即时生成失败，回退使用预生成兜底文案',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {
        'replyLength': reply.length,
        'cacheAgeMinutes': cacheAgeMinutes,
      },
    );
  }
  if (reply == null || reply.isEmpty) {
    print('[Background] AI returned empty reply.');
    await _appendHistoryLog(
      event: 'task_failed_empty_reply',
      message: '后台主动回复任务失败：没有生成可发送内容',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    if (triggerId.isNotEmpty) {
      await _releaseTriggerExecutionClaim(triggerId);
    }
    return;
  }

  final storagePayload = buildBackgroundAssistantStoragePayload(reply);

  // 2. 将消息写入本地存储
  final persisted = await _saveMessageToStorage(convId, storagePayload);
  if (!persisted) {
    await _appendHistoryLog(
      event: 'task_failed_persist_message',
      message: '后台主动回复任务失败：消息未能写入本地会话',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.error,
    );
    if (triggerId.isNotEmpty) {
      await _releaseTriggerExecutionClaim(triggerId);
    }
    return;
  }

  // 3. 尝试发送系统通知；通知失败不影响已写入的主动消息
  try {
    await _showNotification(characterName, storagePayload.displayText);
  } catch (e) {
    await _appendHistoryLog(
      event: 'task_notification_failed',
      message: '后台主动回复通知展示失败，消息已写入本地会话',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {
        'error': e.toString(),
      },
    );
  }

  if (triggerId.isNotEmpty) {
    await _markTriggerAsFired(triggerId);
    await _advanceConversationProactiveStateAfterBackgroundSend(
      triggerId: triggerId,
      conversationId: convId,
    );
  }

  await _appendHistoryLog(
    event: 'task_completed',
    message: '后台主动回复任务执行完成，消息已送达本地会话',
    triggerId: triggerId.isEmpty ? null : triggerId,
    title: triggerTitle,
    conversationId: convId,
    success: true,
    metadata: {
      'usedCachedContent': usedCachedReply,
      'replyLength': storagePayload.rawText.length,
      'displayLength': storagePayload.displayText.length,
    },
  );
}

Future<String?> _fetchAiReply(
  String key,
  String base,
  String model,
  String triggerReminderContent, {
  required String conversationId,
  required String characterName,
  required String userTitle,
  String requestFormat = '',
  String apiPath = '',
  bool vertexExpress = false,
}) async {
  try {
    final split = model.split(':');
    final provider =
        split.length >= 2 ? split.first.trim() : requestFormat.trim();
    final modelName = split.length >= 2 ? split.sublist(1).join(':') : model;
    final baseUrl = base.isEmpty ? 'https://api.openai.com/v1' : base;
    final customConfig = <String, dynamic>{
      if (requestFormat.trim().isNotEmpty)
        'requestFormat': requestFormat.trim(),
      if (apiPath.trim().isNotEmpty) kProviderChatApiPathField: apiPath.trim(),
      if (vertexExpress) 'vertexExpress': true,
    };
    final adapter = ProviderAdapterFactory.getAdapter(
      provider.isEmpty ? 'openai' : provider,
      customConfig: customConfig,
      apiBaseUrl: baseUrl,
    );
    final requestCustomConfig =
        ProviderAdapterFactory.sanitizeRequestCustomConfig(customConfig);
    final endpoint = buildProviderChatEndpoint(
      provider: adapter.name,
      apiBaseUrl: baseUrl,
      model: modelName,
      customConfig: customConfig,
    );
    final canonicalContextMessages =
        await _loadCanonicalContextMessages(conversationId, limit: 10);
    if (canonicalContextMessages.isEmpty) {
      print('[Background] Canonical context is empty, abort live generation.');
      return null;
    }
    final contextMessages = _injectTriggerReminderIntoContext(
      contextMessages: canonicalContextMessages,
      reminderContent: triggerReminderContent,
    );
    final personaUserPrompt =
        await _loadConversationPersonaUserPrompt(conversationId);
    final systemPrompt = buildBackgroundLiveGenerationSystemPrompt(
      characterName: characterName,
      userTitle: userTitle,
      personaUserPrompt: personaUserPrompt,
      now: DateTime.now(),
    );

    final body = adapter.buildRequestBody(
      model: modelName,
      messages: [
        {
          'role': 'system',
          'content': systemPrompt,
        },
        ...contextMessages,
      ],
      temperature: 0.7,
      customConfig: requestCustomConfig,
    );

    final response = await http.post(
      Uri.parse(endpoint),
      headers: {
        'Content-Type': 'application/json',
        ...adapter.buildHeaders(key),
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 200) {
      final json =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final result = adapter.parseResponse(json);
      return result.text;
    } else {
      print('[Background] API Error: ${response.statusCode} ${response.body}');
    }
  } catch (e) {
    print('[Background] Network Error: $e');
  }
  return null;
}

List<Map<String, dynamic>> _injectTriggerReminderIntoContext({
  required List<Map<String, dynamic>> contextMessages,
  required String reminderContent,
}) {
  return _systemReminderService.appendReminderAsLastUser(
    messages: [
      for (final message in contextMessages) Map<String, dynamic>.from(message),
    ],
    reminderContent: reminderContent,
  );
}

Future<List<Map<String, dynamic>>> _loadCanonicalContextMessages(
  String conversationId, {
  required int limit,
}) async {
  final db = AppDatabase();
  try {
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);
    final blockRepo = MessageBlockRepository(db);

    final conversation = await convRepo.getById(conversationId);
    final dbMessages = await msgRepo.getAllByConversationOrderedStable(
      conversationId,
    );
    if (dbMessages.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final messageIds =
        dbMessages.map((message) => message.id).toList(growable: false);
    final dbBlocks = await blockRepo.getByMessages(messageIds);
    final blocksByMessageId = <String, List<MessageBlock>>{};
    for (final dbBlock in dbBlocks) {
      final block = MessageBlockConverter.fromDb(dbBlock);
      if (block == null) {
        continue;
      }
      (blocksByMessageId[dbBlock.messageId] ??= <MessageBlock>[]).add(block);
    }

    final rawMessages = <chat.Message>[
      for (final dbMessage in dbMessages)
        MessageConverter.fromDb(
          dbMessage,
          blocks: blocksByMessageId[dbMessage.id],
        ),
    ];
    final contextMessages = _sliceCanonicalContextWindow(
      allMessages: rawMessages,
      contextStartId: conversation?.contextStartMessageId,
      limit: limit,
    );
    return contextMessages
        .expand((message) => message.toHistoryJsonList())
        .toList(growable: false);
  } catch (e) {
    print('[Background] Failed to load canonical context: $e');
    return const <Map<String, dynamic>>[];
  } finally {
    await db.close();
  }
}

List<chat.Message> _sliceCanonicalContextWindow({
  required List<chat.Message> allMessages,
  required String? contextStartId,
  required int limit,
}) {
  final contextWindow = sliceConversationContext(allMessages, contextStartId);

  if (limit <= 0 || contextWindow.length <= limit) {
    return contextWindow;
  }
  return contextWindow.sublist(contextWindow.length - limit);
}

Future<void> _showNotification(String title, String body) async {
  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidSettings);

  // 重新初始化（因为是在后台 isolate）
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  await flutterLocalNotificationsPlugin.show(
    Random().nextInt(100000), // ID
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'active_reply_channel',
        'Active Reply',
        channelDescription: 'Notifications from your AI companion',
        importance: Importance.max,
        priority: Priority.high,
        styleInformation: BigTextStyleInformation(''), // 支持长文本
      ),
    ),
  );
}

/// 后台任务：将消息写入 SQLite 数据库
/// 注意：后台 isolate 中无法使用 Riverpod，需要创建独立的数据库实例
Future<bool> _saveMessageToStorage(
  String convId,
  BackgroundAssistantStoragePayload payload,
) async {
  final db = AppDatabase();
  try {
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);

    // 检查会话是否存在
    final conv = await convRepo.getById(convId);
    if (conv == null) {
      print('[Background] Conversation not found: $convId');
      return false;
    }

    // 插入消息
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = 'bg_$now';
    await msgRepo.insert(MessagesCompanion(
      id: Value(msgId),
      conversationId: Value(convId),
      role: const Value('assistant'),
      content: Value(payload.rawText),
      status: const Value('sent'),
      createdAt: Value(now),
      rawPayload: Value(jsonEncode(payload.rawPayload)),
    ));

    // 更新会话摘要（lastMessage, lastMessageTime, updatedAt）
    await convRepo.updateSummary(convId, payload.displayText, now);

    // 增加未读数（需要单独更新）
    await (db.update(db.conversations)..where((t) => t.id.equals(convId)))
        .write(ConversationsCompanion(
      unreadCount: Value(conv.unreadCount + 1),
    ));

    print('[Background] Message saved to SQLite.');
    return true;
  } catch (e) {
    print('[Background] SQLite Error: $e');
    return false;
  } finally {
    await db.close();
  }
}

Future<String?> _loadTriggerTitle(
    String triggerId, String conversationId) async {
  if (triggerId.isEmpty) return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;

    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) continue;
      final convId = (map['conversation_id'] as String?) ?? '';
      if (conversationId.isNotEmpty && convId != conversationId) {
        return null;
      }
      return (map['title'] as String?)?.trim();
    }
    return null;
  } catch (e) {
    print('[Background] Failed to load trigger title: $e');
    return null;
  }
}

Future<bool> _isAutoReplyEnabled() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_uiModelsStoreKey);
    if (raw == null || raw.isEmpty) return false;
    final data = jsonDecode(raw);
    if (data is! Map) return false;
    final settings = data['auto_reply_settings'];
    if (settings is! Map) return false;
    return settings['enabled'] == true;
  } catch (e) {
    print('[Background] Failed to read auto-reply setting: $e');
    return false;
  }
}

Future<bool> _isTriggerStillActive(
    String triggerId, String conversationId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return false;

    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) continue;
      final convId = (map['conversation_id'] as String?) ?? '';
      if (conversationId.isNotEmpty && convId != conversationId) {
        return false;
      }
      final status = (map['status'] as String?) ?? '';
      return status == 'created' ||
          status == 'preparing' ||
          status == 'prepared' ||
          status == 'pending';
    }
    return false;
  } catch (e) {
    print('[Background] Failed to inspect trigger state: $e');
    return false;
  }
}

class _BackgroundCachedReply {
  const _BackgroundCachedReply({required this.content, this.preparedAt});

  final String content;
  final DateTime? preparedAt;
}

Future<_BackgroundCachedReply?> _loadCachedTriggerReply(
  String triggerId,
  String conversationId,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;

    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) continue;
      final convId = (map['conversation_id'] as String?) ?? '';
      if (conversationId.isNotEmpty && convId != conversationId) {
        return null;
      }
      final status = (map['status'] as String?) ?? '';
      final isActive = status == 'created' ||
          status == 'preparing' ||
          status == 'prepared' ||
          status == 'pending';
      if (!isActive) return null;
      final cached = (map['cached_content'] as String?)?.trim();
      if (cached == null || cached.isEmpty) return null;
      final preparedAtRaw = (map['prepared_at'] as String?)?.trim();
      final preparedAt = preparedAtRaw == null || preparedAtRaw.isEmpty
          ? null
          : DateTime.tryParse(preparedAtRaw)?.toLocal();
      print('[Background] Loaded cached trigger content. triggerId=$triggerId');
      return _BackgroundCachedReply(content: cached, preparedAt: preparedAt);
    }
    return null;
  } catch (e) {
    print('[Background] Failed to load cached trigger reply: $e');
    return null;
  }
}

Future<void> _markTriggerAsFired(String triggerId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return;

    var changed = false;
    final nowIso = DateTime.now().toIso8601String();
    final updated = decoded.map((item) {
      if (item is! Map) return item;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) return map;
      final status = (map['status'] as String?) ?? '';
      final isActive = status == 'created' ||
          status == 'preparing' ||
          status == 'prepared' ||
          status == 'pending';
      if (!isActive) return map;
      changed = true;
      map['status'] = 'fired';
      map['last_fired_at'] = nowIso;
      map['expire_reason'] = null;
      return map;
    }).toList();

    if (changed) {
      await prefs.setString(_triggerStoreKey, jsonEncode(updated));
    }
  } catch (e) {
    print('[Background] Failed to mark trigger fired: $e');
  }
}

Future<void> _advanceConversationProactiveStateAfterBackgroundSend({
  required String triggerId,
  required String conversationId,
}) async {
  try {
    final source = await _loadTriggerSource(triggerId, conversationId);
    if (source != TriggerSource.aiScheduler.name) {
      return;
    }

    final storage = ConversationProactiveStateStorage();
    final states = await storage.loadStates();
    final current = states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    final next = current
        .clearPendingAutoTrigger(triggerId: triggerId)
        .afterSuccessfulAutoTriggerSend(occurredAt: DateTime.now());
    states[conversationId] = next;
    await storage.saveStates(states);
  } catch (e) {
    print('[Background] Failed to advance proactive state: $e');
  }
}

Future<String?> _loadTriggerSource(
  String triggerId,
  String conversationId,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;

    for (final item in decoded) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item.cast<String, dynamic>());
      if ((map['id'] as String?) != triggerId) continue;
      final convId = (map['conversation_id'] as String?) ?? '';
      if (conversationId.isNotEmpty && convId != conversationId) {
        return null;
      }
      return (map['source'] as String?)?.trim();
    }
    return null;
  } catch (e) {
    print('[Background] Failed to load trigger source: $e');
    return null;
  }
}

// 前台调用的初始化方法
class BackgroundService {
  static Future<void> initialize() async {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false, // 生产环境改为 false
    );
  }

  static Future<void> scheduleOneOffTask({
    required String uniqueName,
    required Duration delay,
    required Map<String, dynamic> inputData,
  }) async {
    await Workmanager().registerOneOffTask(
      uniqueName,
      taskNameActiveReply,
      initialDelay: delay,
      inputData: inputData,
      constraints: Constraints(
        networkType: NetworkType.connected, // 必须有网
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace, // 如果ID相同则替换
    );
  }

  static Future<void> cancelTaskByTriggerId(String triggerId) async {
    if (triggerId.isEmpty) return;
    await Workmanager().cancelByUniqueName('trigger_$triggerId');
  }
}
