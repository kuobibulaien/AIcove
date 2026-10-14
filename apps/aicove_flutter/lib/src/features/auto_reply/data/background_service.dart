// ignore_for_file: avoid_print
// 注意：此文件在后台 isolate 中运行，无法使用 AppLogger（依赖 Flutter framework）。
// 这里的 print 语句仅用于后台调试，在 release 模式下不会输出。
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/database/database.dart' hide MessageBlock;
import '../../../core/database/database_provider.dart';
import '../../../core/database/repositories/repositories.dart';
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
import 'incoming_call_notification.dart';
import 'proactive_call_ledger.dart';
import 'proactive_reply_generator.dart';

// 任务名称常量
const String taskNameActiveReply = 'com.aicove.active_reply';
const String _uiModelsStoreKey = 'aicove.ui_models.v1';
const String _triggerStoreKey = 'aicove.auto_triggers.v1';
final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

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

/// 后台尝试认领触发器执行权；返回令牌，null 表示未认领到。
/// 数据库异常时按「保唯一性」原则返回 null，由前台补发。
Future<String?> _tryClaimTriggerExecution(String triggerId) =>
    _withClaimStore(
      (store) => store.tryClaim(
        triggerId: triggerId,
        claimedBy: AutoReplyClaimOwner.background,
      ),
      fallback: null,
      what: 'claim trigger execution',
    );

/// 后台发送失败后释放执行权，让前台/重试可以重新认领。
Future<void> _releaseTriggerExecutionClaim(String triggerId, String token) =>
    _withClaimStore(
      (store) => store.release(triggerId, token),
      fallback: null,
      what: 'release trigger claim',
    );

/// 每步单独开关一次数据库：前台或上一步的连接还没完全关时会撞上
/// “database is locked”，有界重试，免得把一时的锁冲突当成“被接管”。
Future<T> _withClaimStore<T>(
  Future<T> Function(AutoReplyClaimStore store) body, {
  required T fallback,
  required String what,
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await body(AutoReplyClaimStore(_taskDatabase()));
    } catch (e) {
      // 前台连接的写事务可能占锁好几秒：退避总计约 12 秒，仍失败才放弃。
      if (_isSqliteLock(e) && attempt < 8) {
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
        continue;
      }
      print('[Background] Failed to $what: $e');
      return fallback;
    }
  }
}

/// 一次任务共用一个数据库连接（含生成用的容器）。逐步开关连接时，上一个
/// 连接在后台 isolate 里还没真正关掉，下一次打开就会撞上锁。
AppDatabase? _taskDb;

AppDatabase _taskDatabase() => _taskDb ??= AppDatabase();

Future<void> _runActiveReplyTask(Map<String, dynamic> data) async {
  try {
    await _handleActiveReplyTask(data);
  } finally {
    final db = _taskDb;
    _taskDb = null;
    await db?.close();
  }
}

/// SQLITE_BUSY / SQLITE_LOCKED, also when wrapped by drift's isolate channel.
bool _isSqliteLock(Object error) {
  final text = error.toString();
  return text.contains('(code 5)') || text.contains('(code 6)');
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
        await _runActiveReplyTask(inputData);
      } catch (e) {
        print('[Background] Error: $e');
        return Future.value(false);
      }
    }
    return Future.value(true);
  });
}

/// WorkManager 任务本体的测试入口：同一个函数，不经 WorkManager 调度。
@visibleForTesting
Future<void> runActiveReplyTaskForTest(Map<String, dynamic> data) =>
    _runActiveReplyTask(data);

// 具体的任务逻辑
Future<void> _handleActiveReplyTask(Map<String, dynamic> data) async {
  final String triggerId = data['triggerId'] ?? '';
  final String prompt = data['prompt'] ?? '';
  final String? contextSnapshot = data['contextSnapshot'] as String?;
  final String convId = data['convId'] ?? '';
  final String characterName = data['characterName'] ?? 'AIcove';
  final triggerTitle = await _loadTriggerTitle(triggerId, convId);

  // 模型配置不随任务快照：执行时现读最新设置（换 key/换模型立即生效，
  // 密钥不落地 WorkManager）。旧版任务 inputData 中的配置仅作升级期兜底。
  // 即时生成与前台同走聊天装配入口（ADR0060），这里只用它判断能否生成。
  final requestConfig = await _loadBackgroundRequestConfig();
  final String apiKey;
  final String model;
  if (requestConfig != null) {
    apiKey = requestConfig.providerApiKey ?? '';
    model = requestConfig.modelFullId;
  } else {
    apiKey = data['apiKey'] ?? '';
    model = data['model'] ?? '';
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

  // 执行权认领：与前台轮询链路互斥，认领失败说明另一方正在执行或已送达
  String? claimToken;
  if (triggerId.isNotEmpty) {
    claimToken = await _tryClaimTriggerExecution(triggerId);
    for (var attempt = 0; claimToken == null; attempt++) {
      if (!await _handleClaimLost(
        triggerId: triggerId,
        convId: convId,
        title: triggerTitle,
        data: data,
      )) {
        return;
      }
      // 认领已空出却连续没抢到：状态在反复变化，交给 WorkManager 重试，
      // 不能按成功结束。
      if (attempt >= 2) {
        throw StateError('执行权多次空出仍未认领到：$triggerId');
      }
      claimToken = await _tryClaimTriggerExecution(triggerId);
    }
    // 上次已写入消息、却在标记 fired 前被杀：只补完收尾，不重复发送。
    if (await _isTriggerMessageDelivered(convId, triggerId)) {
      await _withClaimStore(
        (store) => store.beginDelivery(
          triggerId,
          claimToken!,
          messageId: backgroundTriggerMessageId(triggerId),
        ),
        fallback: false,
        what: 'mark recovered delivery',
      );
      await _finishDeliveredTrigger(triggerId, convId);
      await _appendHistoryLog(
        event: 'task_recovered_delivered',
        message: '后台主动回复上次已送达，本次只补标记，不重复发送',
        triggerId: triggerId,
        title: triggerTitle,
        conversationId: convId,
        success: true,
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
  if (cacheFresh &&
      cached.action == ProactiveAction.callUser &&
      claimToken != null &&
      await _ringInBackground(
        triggerId: triggerId,
        convId: convId,
        title: triggerTitle,
        characterName: characterName,
        openingLine: cached.content,
        claimToken: claimToken,
      )) {
    return;
  }
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
    if (claimToken != null) {
      await _releaseTriggerExecutionClaim(triggerId, claimToken);
    }
    return;
  }
  reply ??= await _generateLiveReply(
    conversationId: convId,
    reminder: prompt,
    triggerId: triggerId,
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
    if (claimToken != null) {
      await _releaseTriggerExecutionClaim(triggerId, claimToken);
    }
    return;
  }

  final storagePayload = buildBackgroundAssistantStoragePayload(reply);

  // 开始送达：仍持有认领才写消息；生成期间被另一方接管则放弃，避免重复。
  if (claimToken != null &&
      !await _withClaimStore(
        (store) => store.beginDelivery(
          triggerId,
          claimToken!,
          messageId: backgroundTriggerMessageId(triggerId),
        ),
        fallback: false,
        what: 'begin delivery',
      )) {
    await _appendHistoryLog(
      event: 'task_superseded',
      message: '后台主动回复已放弃：生成期间执行权被另一方接管',
      triggerId: triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return;
  }

  // 2. 将消息写入本地存储
  final persisted = await _saveMessageToStorage(
    convId,
    storagePayload,
    messageId: triggerId.isEmpty
        ? 'bg_${DateTime.now().millisecondsSinceEpoch}'
        : backgroundTriggerMessageId(triggerId),
  );
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
    // 写入在事务里失败，什么都没写进去：撤销认领，让下一次重试接手。
    if (claimToken != null) {
      await _withClaimStore(
        (store) => store.abortDelivery(triggerId, claimToken!),
        fallback: null,
        what: 'abort delivery',
      );
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
    await _finishDeliveredTrigger(triggerId, convId);
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

/// 无界面装配：在本 isolate 内建一个 ProviderContainer，经聊天装配入口
/// `prepareApiConfig` 生成，与前台主动回复同一条链路（ADR0060）。
Future<String?> _generateLiveReply({
  required String conversationId,
  required String reminder,
  required String triggerId,
}) async {
  try {
    return await generateHeadlessProactiveReply(
      conversationId: conversationId,
      reminder: reminder,
      turnId: 'auto_reply_background_$triggerId',
      overrides: [databaseProvider.overrideWithValue(_taskDatabase())],
    );
  } catch (e) {
    print('[Background] Live generation failed: $e');
    return null;
  }
}

/// 一个触发器只对应一条主动消息：编号固定，崩溃后重试不会重复写入。
String backgroundTriggerMessageId(String triggerId) => 'bg_trigger_$triggerId';

/// [messageId] 是开始送达时记下的第一条消息；没有时按后台固定编号查。
Future<bool> _isTriggerMessageDelivered(
  String conversationId,
  String triggerId, {
  String? messageId,
}) async {
  try {
    final existing = await MessageRepository(_taskDatabase())
        .getById(messageId ?? backgroundTriggerMessageId(triggerId));
    return existing != null &&
        (messageId != null || existing.conversationId == conversationId);
  } catch (e) {
    print('[Background] Failed to check delivered message: $e');
    return false;
  }
}

/// 角色想打电话、App 在后台（方案 12 §13）：占到唯一的响铃位后发一条带
/// 「接听」「拒绝」的来电通知，由 App 接通或结算为未接。返回 false 时照常把
/// 开场白当消息发出去：只在 Android 上、开关仍开着、没有因连续未接暂停、
/// 没有别的来电在响时才打。音色和识别是否可用只能在 App 里检查，预生成时
/// 已经查过；App 里正在进行的通话这里看不到。
Future<bool> _ringInBackground({
  required String triggerId,
  required String convId,
  required String? title,
  required String characterName,
  required String openingLine,
  required String claimToken,
}) async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  final settings = await _loadAutoReplySettingsMap();
  final ledger = ProactiveCallLedger(_taskDatabase());
  final String? blocked = settings['allow_proactive_calls'] != true
      ? '主动来电已关闭'
      : await ledger.callsPaused(convId)
      ? '连续没接，暂停主动来电'
      : null;
  final now = DateTime.now();
  if (blocked != null ||
      !await ledger.reserve(
        ProactiveCall(
          triggerId: triggerId,
          conversationId: convId,
          openingLine: openingLine,
          rangAt: now,
          answerUntil: now.add(backgroundCallAnswerWindow),
        ),
      )) {
    await _appendHistoryLog(
      event: 'task_call_sent_as_message',
      message: '这次不打电话，改发消息：${blocked ?? '另一通来电还在响'}',
      triggerId: triggerId,
      title: title,
      conversationId: convId,
    );
    return false;
  }
  if (!await _withClaimStore(
    (store) => store.beginDelivery(triggerId, claimToken),
    fallback: false,
    what: 'begin call delivery',
  )) {
    await ledger.release(triggerId);
    await _appendHistoryLog(
      event: 'task_superseded',
      message: '后台来电已放弃：执行权被另一方接管',
      triggerId: triggerId,
      title: title,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return true;
  }
  await ledger.confirm(triggerId);
  try {
    await showIncomingCallNotification(
      triggerId: triggerId,
      characterName: characterName,
    );
  } catch (e) {
    await _appendHistoryLog(
      event: 'task_call_notification_failed',
      message: '来电通知没有弹出，到时会记为未接来电',
      triggerId: triggerId,
      title: title,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {'error': e.toString()},
    );
  }
  await _finishDeliveredTrigger(triggerId, convId);
  await _appendHistoryLog(
    event: 'task_call_ringing',
    message: '角色来电：已发出来电通知',
    triggerId: triggerId,
    title: title,
    conversationId: convId,
    success: true,
  );
  return true;
}

/// 送达后的收尾：标记 fired、推进会话主动状态。认领已在开始送达时完成。
Future<void> _finishDeliveredTrigger(
  String triggerId,
  String conversationId,
) async {
  await _markTriggerAsFired(triggerId);
  await _advanceConversationProactiveStateAfterBackgroundSend(
    triggerId: triggerId,
    conversationId: conversationId,
  );
}

/// 没认领到时的处理；返回 true 表示认领已空出、可以再认领一次。
///
/// - 已开始送达：一个租约内对方可能还在写，改期到送达租约结束后再来看；
///   超过租约视为对方已中断，不重试，按记下的消息是否存在补成已送达或中断
///   作废。
/// - 另一方仍在租约内：改期到租约过期后再试（WorkManager 会把本次返回当作
///   成功，不改期的话对方中途被杀就无人接手）。
/// - 状态读不到或改期失败：抛出，让 WorkManager 按失败重试。
Future<bool> _handleClaimLost({
  required String triggerId,
  required String convId,
  required String? title,
  required Map<String, dynamic> data,
}) async {
  final state = await _withClaimStore<AutoReplyClaimState?>(
    (store) => store.stateOf(triggerId),
    fallback: null,
    what: 'read claim state',
  );
  switch (state) {
    case null:
      throw StateError('无法读取执行权状态：$triggerId');
    case AutoReplyClaimFree():
      return true;
    case AutoReplyClaimDelivered(:final startedAt)
        when !state.isStalled(DateTime.now()):
      // 对方若在写入中被杀，没人会再来收尾：留一次租约后的检查，改期失败
      // 就抛出，让 WorkManager 重试。
      await _rescheduleBackgroundTask(
        triggerId: triggerId,
        data: data,
        delay: startedAt
                .add(AutoReplyClaimStore.lease)
                .difference(DateTime.now()) +
            const Duration(minutes: 1),
      );
      print('[Background] Delivery in progress elsewhere, rescheduled past '
          'its lease. triggerId=$triggerId');
      return false;
    case AutoReplyClaimDelivered(:final messageId):
      final delivered = await _isTriggerMessageDelivered(
        convId,
        triggerId,
        messageId: messageId,
      );
      if (delivered) {
        await _finishDeliveredTrigger(triggerId, convId);
      } else {
        await _markTriggerTerminal(
          triggerId,
          status: 'expired',
          reason: interruptedDeliveryReason,
        );
      }
      await _appendHistoryLog(
        event: 'task_delivery_interrupted_finalized',
        message: delivered
            ? '后台主动回复上次送达后中断，补记为已送达'
            : '后台主动回复上次开始送达后中断，不重试',
        triggerId: triggerId,
        title: title,
        conversationId: convId,
        success: delivered,
        level: delivered
            ? AutoReplyTriggerLogLevel.info
            : AutoReplyTriggerLogLevel.warning,
      );
      return false;
    case AutoReplyClaimHeld(:final leaseEndsAt):
      await _rescheduleBackgroundTask(
        triggerId: triggerId,
        data: data,
        delay: leaseEndsAt.difference(DateTime.now()) +
            const Duration(minutes: 1),
      );
      print('[Background] Trigger claimed elsewhere, rescheduled past lease. '
          'triggerId=$triggerId');
      await _appendHistoryLog(
        event: 'task_skipped_claim_lost',
        message: '后台主动回复暂缓：另一方正在执行，租约过期后再试',
        triggerId: triggerId,
        title: title,
        conversationId: convId,
        success: false,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return false;
  }
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
  BackgroundAssistantStoragePayload payload, {
  required String messageId,
}) async {
  final db = _taskDatabase();
  try {
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);

    // 检查会话是否存在
    final conv = await convRepo.getById(convId);
    if (conv == null) {
      print('[Background] Conversation not found: $convId');
      return false;
    }

    // 已写入过（崩溃后重试）：视为已送达，不重复插入、不重复加未读
    if (await msgRepo.getById(messageId) != null) {
      print('[Background] Message already delivered: $messageId');
      return true;
    }

    // 消息、会话摘要与未读数同一事务写入：有消息就一定有摘要和未读，
    // 崩溃恢复只需看消息是否存在。
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction(() async {
      await msgRepo.insert(MessagesCompanion(
        id: Value(messageId),
        conversationId: Value(convId),
        role: const Value('assistant'),
        content: Value(payload.rawText),
        status: const Value('sent'),
        createdAt: Value(now),
        rawPayload: Value(jsonEncode(payload.rawPayload)),
      ));
      await convRepo.updateSummary(convId, payload.displayText, now);
      await db.customUpdate(
        'UPDATE conversations SET unread_count = unread_count + 1 WHERE id = ?',
        variables: [Variable.withString(convId)],
        updates: {db.conversations},
      );
    });

    print('[Background] Message saved to SQLite.');
    return true;
  } catch (e) {
    print('[Background] SQLite Error: $e');
    return false;
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
  const _BackgroundCachedReply({
    required this.content,
    this.preparedAt,
    this.action = ProactiveAction.sendMessage,
  });

  final String content;
  final DateTime? preparedAt;
  final ProactiveAction action;
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
      return _BackgroundCachedReply(
        content: cached,
        preparedAt: preparedAt,
        action: ProactiveAction.fromId(map['action'] as String?),
      );
    }
    return null;
  } catch (e) {
    print('[Background] Failed to load cached trigger reply: $e');
    return null;
  }
}

Future<void> _markTriggerAsFired(String triggerId) =>
    _markTriggerTerminal(triggerId, status: 'fired');

Future<void> _markTriggerTerminal(
  String triggerId, {
  required String status,
  String? reason,
}) async {
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
      final current = (map['status'] as String?) ?? '';
      final isActive = current == 'created' ||
          current == 'preparing' ||
          current == 'prepared' ||
          current == 'pending';
      if (!isActive) return map;
      changed = true;
      map['status'] = status;
      map['last_fired_at'] = nowIso;
      map['expire_reason'] = reason;
      return map;
    }).toList();

    if (changed) {
      await prefs.setString(_triggerStoreKey, jsonEncode(updated));
    }
  } catch (e) {
    print('[Background] Failed to mark trigger $status: $e');
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
