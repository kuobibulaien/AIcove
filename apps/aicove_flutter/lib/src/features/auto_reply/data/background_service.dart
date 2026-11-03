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

import '../../observability/background_delivery_diagnostics.dart';
import '../../../core/database/database.dart' hide MessageBlock;
import '../../../core/database/converters/database_converters.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/media/media_store.dart';
import '../../../core/sync/cloud_setting_policy.dart';
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
import 'proactive_owner_device.dart';
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
  final payloadProcessedText = processedText.isNotEmpty
      ? processedText
      : displayText;
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

/// 与前台 `_pollDueTriggers()` 同源的发送门禁：按联系人夜间免打扰时段判断。
/// 返回 null 表示放行。
@visibleForTesting
BackgroundSendGateResult? evaluateBackgroundSendGates({
  required DateTime now,
  required Map<String, dynamic> autoReplySettings,
  required bool triggerAllowNight,
  required List<Map<String, dynamic>> allTriggers,
  String? conversationId,
}) {
  final resolved = AutoReplySettings.fromJson(
    autoReplySettings,
  ).forContact(conversationId);
  final quietEnabled = resolved.quietHoursEnabled;
  final quietStart = resolved.quietHoursStart;
  final quietEnd = resolved.quietHoursEnd;
  if (quietEnabled &&
      !triggerAllowNight &&
      isWithinQuietHoursWindow(now, start: quietStart, end: quietEnd)) {
    return BackgroundSendGateResult(
      reason: 'quiet_hours',
      retryDelay: delayUntilQuietHoursEnd(now, quietEnd),
    );
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
    rethrow;
  }
}

/// 执行时现读模型请求配置（默认聊天模型 + 供应商 + 直连兜底）。
/// 返回 null 表示设置不可读，调用方回退旧任务携带的配置快照。
Future<AutoReplyRequestConfig?> _loadBackgroundRequestConfig(
  String convId,
) async {
  final AppSettings settings;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_uiModelsStoreKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    settings = mapUiModelsToAppSettings(
      Map<String, dynamic>.from(decoded.cast<String, dynamic>()),
    );
  } catch (e) {
    print('[Background] Failed to resolve request config: $e');
    rethrow;
  }
  // 读库失败不能当成“没选模型”退回全局模型：直接抛出，交给 WorkManager 重试。
  final sessionModel = await _loadSessionModel(convId);
  return resolveAutoReplyRequestConfig(settings, sessionModel: sessionModel);
}

/// 目标会话自己选的聊天模型；没选过返回 null（退回默认队列），读库失败抛出。
Future<String?> _loadSessionModel(String convId) async {
  if (convId.isEmpty) return null;
  return _withTaskDb((db) async {
    final row = await db
        .customSelect(
          'SELECT session_provider FROM conversations WHERE id = ?',
          variables: [Variable.withString(convId)],
        )
        .getSingleOrNull();
    return row?.read<String?>('session_provider');
  });
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
    rethrow;
  }
}

Future<void> _rescheduleBackgroundTask({
  required String triggerId,
  required Map<String, dynamic> data,
  required Duration delay,
}) async {
  final normalizedDelay = delay < const Duration(minutes: 1)
      ? const Duration(minutes: 1)
      : delay;
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
/// 数据库异常向上传递，由 WorkManager 重试。
Future<String?> _tryClaimTriggerExecution(String triggerId) => _withClaimStore(
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
  try {
    return await _withTaskDb((db) => body(AutoReplyClaimStore(db)));
  } catch (e) {
    print('[Background] Failed to $what: $e');
    rethrow;
  }
}

/// 在任务连接上执行 [body]，撞锁时有界重试；仍失败就抛出。
Future<T> _withTaskDb<T>(Future<T> Function(AppDatabase db) body) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await body(await _taskDatabase());
    } catch (e) {
      // 前台连接的写事务可能占锁好几秒：退避总计约 12 秒，仍失败才放弃。
      if (_isSqliteLock(e) && attempt < 8) {
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
        continue;
      }
      rethrow;
    }
  }
}

/// 一次任务共用一个数据库连接（含生成用的容器）。逐步开关连接时，上一个
/// 连接在后台 isolate 里还没真正关掉，下一次打开就会撞上锁。
AppDatabase? _taskDb;
Stopwatch? _taskClock;

/// 打开成功才缓存：drift 把打开阶段（读 schema 版本）的失败永久记在连接上，
/// 撞锁后复用同一连接，重试只会读回旧错误，所以失败的连接直接关掉重开。
Future<AppDatabase> _taskDatabase() async {
  final cached = _taskDb;
  if (cached != null) return cached;
  final db = AppDatabase();
  try {
    await db.customSelect('SELECT 1').get();
  } catch (_) {
    await db.close();
    rethrow;
  }
  final raced = _taskDb;
  if (raced != null) {
    await db.close();
    return raced;
  }
  return _taskDb = db;
}

Future<void> _runActiveReplyTask(Map<String, dynamic> data) async {
  _taskClock = Stopwatch()..start();
  try {
    await _handleActiveReplyTask(data);
  } finally {
    final db = _taskDb;
    _taskDb = null;
    _taskClock = null;
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
  if (firstPartyContentTagScanner
      .scan(rawText)
      .any(
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
  await recordBackgroundDelivery(
    event: event,
    entityId: triggerId == null
        ? 'background'
        : backgroundTriggerMessageId(triggerId),
    conversationId: conversationId,
    phase: category.name,
    success: success,
    elapsedMs: _taskClock?.elapsedMilliseconds ?? 0,
  );
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
      return _backgroundTaskResult(() => _runActiveReplyTask(inputData));
    }
    return Future.value(true);
  });
}

Future<bool> _backgroundTaskResult(Future<void> Function() run) async {
  try {
    await run();
    return true;
  } catch (e) {
    print('[Background] Error: $e');
    return false;
  }
}

/// Uses the callback's exact success/failure mapping without scheduling work.
@visibleForTesting
Future<bool> backgroundTaskResultForTest(Future<void> Function() run) =>
    _backgroundTaskResult(run);

/// WorkManager 任务本体的测试入口：同一个函数，不经 WorkManager 调度。
@visibleForTesting
Future<void> runActiveReplyTaskForTest(
  Map<String, dynamic> data, {
  Future<void> Function()? beforePersist,
  Future<void> Function()? beforeCallConfirm,
  Future<void> Function()? afterPersist,
  Future<String?> Function(String reminder)? generate,
}) => runZoned(
  () => _runActiveReplyTask(data),
  zoneValues: {
    _beforeBackgroundPersistKey: beforePersist,
    #beforeBackgroundCallConfirm: beforeCallConfirm,
    #afterBackgroundPersist: afterPersist,
    #backgroundGenerate: generate,
  },
);

const _beforeBackgroundPersistKey = #beforeBackgroundPersist;

// 具体的任务逻辑
Future<void> _handleActiveReplyTask(Map<String, dynamic> data) async {
  final String triggerId = data['triggerId'] ?? '';
  final latestTrigger = await _loadBackgroundTrigger(
    triggerId,
    data['convId'] ?? '',
  );
  // Persisted triggers own their current prompt; task data is legacy-only.
  final String prompt = latestTrigger == null
      ? (triggerId.isEmpty ? (data['prompt'] as String? ?? '') : '')
      : (latestTrigger.prompt?.trim().isNotEmpty == true
            ? latestTrigger.prompt!.trim()
            : latestTrigger.title);
  final String? contextSnapshot = data['contextSnapshot'] as String?;
  final String convId = data['convId'] ?? '';
  final String characterName = data['characterName'] ?? 'AIcove';
  final triggerTitle = await _loadTriggerTitle(triggerId, convId);

  // 模型配置不随任务快照：执行时现读最新设置（换 key/换模型立即生效，
  // 密钥不落地 WorkManager）。旧版任务 inputData 中的配置仅作升级期兜底。
  // 即时生成与前台同走聊天装配入口（ADR0060），这里只用它判断能否生成。
  final requestConfig = await _loadBackgroundRequestConfig(convId);
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
        '[Background] Trigger is no longer active, skip task. triggerId=$triggerId',
      );
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

  // 用户已换到另一台设备说话：这个会话的主动回复归那台设备负责。
  if (!(await ProactiveOwnership.load()).owns(convId)) {
    await _appendHistoryLog(
      event: 'task_skipped_other_device',
      message: '后台主动回复任务已跳过：这个会话由另一台设备负责',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return;
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
      conversationId: convId,
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
          rethrow;
        }
      }
      print(
        '[Background] Send gated by ${gate.reason}, rescheduled=$rescheduled',
      );
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
    if (await _isTriggerDelivered(convId, triggerId)) {
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

  Future<bool> cancelIfStale() async {
    final reason = await _backgroundDeliveryInvalidReason(
      await _taskDatabase(),
      conversationId: convId,
      triggerId: triggerId,
    );
    if (reason == null) return false;
    if (claimToken != null) {
      await _releaseTriggerExecutionClaim(triggerId, claimToken);
    }
    if (triggerId.isNotEmpty && reason != 'other_device') {
      await _markTriggerTerminal(triggerId, status: 'expired', reason: reason);
    }
    await _appendHistoryLog(
      event: 'task_skipped_stale_context',
      message: '后台主动回复已取消：会话已删除或触发上下文已过期',
      triggerId: triggerId.isEmpty ? null : triggerId,
      conversationId: convId,
      success: false,
    );
    return true;
  }

  if (await cancelIfStale()) return;

  // 1. 读取预生成缓存：新鲜缓存直接发送；过期缓存降级为兜底文案
  final cached = triggerId.isEmpty
      ? null
      : await _loadCachedTriggerReply(triggerId, convId);
  final cachedReply = cached?.content;
  final cacheNow = DateTime.now();
  final cacheFresh =
      cached != null &&
      isCachedAutoReplyContentFresh(
        preparedAt: cached.preparedAt,
        now: cacheNow,
      );
  final canFallback =
      cached != null &&
      isCachedAutoReplyContentFresh(
        preparedAt: cached.preparedAt,
        now: cacheNow,
        maxAge: const Duration(hours: 6),
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
  } else if (canFallback && cachedReply != null && apiKey.trim().isEmpty) {
    // 没有模型配置时，仅使用六小时内的缓存兜底。
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
      message: '预生成缓存已过期，后台任务改为即时生成',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      metadata: {'cacheAgeMinutes': cacheAgeMinutes},
    );
  }

  if (shouldSkipBackgroundActiveReplyForMissingModelConfig(
    apiKey: apiKey,
    cachedReply: canFallback ? cachedReply : null,
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
    throw StateError('后台主动回复缺少可用模型配置');
  }
  reply ??= await _generateLiveReply(
    conversationId: convId,
    reminder: prompt,
    triggerId: triggerId,
  );
  // Cancellation must precede the stale-cache fallback as well as persistence.
  if (await cancelIfStale()) return;
  reply = reply?.trim();
  if (!usedCachedReply && reply != null && reply.isNotEmpty) {
    await _appendHistoryLog(
      event: 'task_generated_live_reply',
      message: '后台任务已即时生成主动回复文案',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      category: AutoReplyTriggerLogCategory.agent,
      success: true,
      metadata: {'replyLength': reply.length},
    );
  }
  if ((reply == null || reply.isEmpty) &&
      canFallback &&
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
    throw StateError('后台主动回复生成失败或内容为空');
  }

  final storagePayload = buildBackgroundAssistantStoragePayload(reply);

  // 开始送达：仍持有认领、仍是负责设备才写消息；生成期间被另一方或另一台
  // 设备接管则放弃，避免重复。
  // 交给另一台设备时放掉本机认领（用户回到本机还能马上再触发），并直接放弃：
  // 释放可能因锁失败，不能指望随后的 beginDelivery 一定失败。
  final handedOff = !(await ProactiveOwnership.load()).owns(convId);
  if (claimToken != null && handedOff) {
    await _releaseTriggerExecutionClaim(triggerId, claimToken);
  }
  if (claimToken != null &&
      (handedOff ||
          !await _withClaimStore(
            (store) => store.beginDelivery(
              triggerId,
              claimToken!,
              messageId: backgroundTriggerMessageId(triggerId),
            ),
            fallback: false,
            what: 'begin delivery',
          ))) {
    await _appendHistoryLog(
      event: 'task_superseded',
      message: '后台主动回复已放弃：生成期间执行权被另一方或另一台设备接管',
      triggerId: triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
    );
    return;
  }

  // 2. 将消息写入本地存储
  final bool persisted;
  try {
    persisted = await _saveMessageToStorage(
      convId,
      storagePayload,
      triggerId: triggerId,
      messageId: triggerId.isEmpty
          ? 'bg_${DateTime.now().millisecondsSinceEpoch}'
          : backgroundTriggerMessageId(triggerId),
    );
  } catch (_) {
    if (claimToken != null) {
      await _withClaimStore(
        (store) => store.abortDelivery(triggerId, claimToken!),
        fallback: null,
        what: 'abort failed persistence',
      );
    }
    rethrow;
  }
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
    // 返回 false 只表示终态取消；数据库异常已抛出并撤销送达认领。
    if (claimToken != null) {
      await _withClaimStore(
        (store) => store.abortDelivery(triggerId, claimToken!),
        fallback: null,
        what: 'abort delivery',
      );
    }
    if (await cancelIfStale()) return;
    if (triggerId.isNotEmpty) {
      await _markTriggerTerminal(
        triggerId,
        status: 'expired',
        reason: 'delivery_anchor_no_longer_active',
      );
    }
    return;
  }
  final afterPersist =
      Zone.current[#afterBackgroundPersist] as Future<void> Function()?;
  await afterPersist?.call();

  // 3. 尝试发送系统通知；通知失败不影响已写入的主动消息
  final mayNotify = await _isBackgroundDeliveryCurrent(
    await _taskDatabase(),
    conversationId: convId,
    triggerId: triggerId,
  );
  try {
    if (mayNotify) {
      await _showNotification(characterName, storagePayload.displayText);
    }
  } catch (e) {
    await _appendHistoryLog(
      event: 'task_notification_failed',
      message: '后台主动回复通知展示失败，消息已写入本地会话',
      triggerId: triggerId.isEmpty ? null : triggerId,
      title: triggerTitle,
      conversationId: convId,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {'error': e.toString()},
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
    final db = await _taskDatabase();
    return await _generateBackgroundReplyIfCurrent(
      database: db,
      conversationId: conversationId,
      triggerId: triggerId,
      generate: () async {
        final trigger = await _loadBackgroundTrigger(triggerId, conversationId);
        final latestReminder = trigger == null
            ? reminder
            : (trigger.prompt?.trim().isNotEmpty == true
                ? trigger.prompt!.trim() : trigger.title);
        final generate =
            Zone.current[#backgroundGenerate]
                as Future<String?> Function(String)?;
        if (generate != null) return generate(latestReminder);
        return generateHeadlessProactiveReply(
          conversationId: conversationId,
          reminder: latestReminder,
          turnId: 'auto_reply_background_$triggerId',
          overrides: [databaseProvider.overrideWithValue(db)],
        );
      },
    );
  } catch (e) {
    print('[Background] Live generation failed: $e');
    return null;
  }
}

/// Runs the production lifecycle gates with an injectable generation boundary.
@visibleForTesting
Future<String?> generateBackgroundLiveReplyForTest({
  required AppDatabase database,
  required String conversationId,
  required String triggerId,
  required Future<String?> Function() generate,
}) => _generateBackgroundReplyIfCurrent(
  database: database,
  conversationId: conversationId,
  triggerId: triggerId,
  generate: generate,
);

Future<String?> _generateBackgroundReplyIfCurrent({
  required AppDatabase database,
  required String conversationId,
  required String triggerId,
  required Future<String?> Function() generate,
}) async {
  if (!await _isBackgroundDeliveryCurrent(
    database,
    conversationId: conversationId,
    triggerId: triggerId,
  )) {
    return null;
  }
  final reply = await generate();
  if (!await _isBackgroundDeliveryCurrent(
    database,
    conversationId: conversationId,
    triggerId: triggerId,
  )) {
    return null;
  }
  return reply;
}

Future<AutoReplyTrigger?> _loadBackgroundTrigger(
  String triggerId,
  String conversationId,
) async {
  if (triggerId.isEmpty) return null;
  final trigger = (await _loadAllTriggerMaps())
      .where((item) => item['id'] == triggerId)
      .map(AutoReplyTrigger.fromJson)
      .firstOrNull;
  return trigger?.conversationId == conversationId ? trigger : null;
}

Future<bool> _isBackgroundDeliveryCurrent(
  AppDatabase db, {
  required String conversationId,
  required String triggerId,
}) async =>
    await _backgroundDeliveryInvalidReason(
      db,
      conversationId: conversationId,
      triggerId: triggerId,
    ) ==
    null;

Future<String?> _backgroundDeliveryInvalidReason(
  AppDatabase db, {
  required String conversationId,
  required String triggerId,
}) async {
  final conversation = await ConversationRepository(db).getById(conversationId);
  if (conversation == null || conversation.deletedAt != null) {
    return 'conversation_deleted';
  }
  if (!(await ProactiveOwnership.load()).owns(conversationId)) {
    return 'other_device';
  }
  if (triggerId.isEmpty) return null; // Legacy tasks have no trigger snapshot.
  final trigger = await _loadBackgroundTrigger(triggerId, conversationId);
  if (trigger == null || !trigger.isActive) return 'trigger_inactive';
  if (trigger.source == TriggerSource.aiScheduler &&
      !ConversationConverter.fromDb(conversation).allowsPlugin('trigger')) {
    return 'trigger_plugin_disabled';
  }
  final latestUser =
      await (db.select(db.messages)
            ..where(
              (row) =>
                  row.conversationId.equals(conversationId) &
                  row.role.equals('user') &
                  row.deletedAt.isNull() &
                  row.replacedBy.isNull(),
            )
            ..orderBy([
              (row) => OrderingTerm.desc(row.createdAt),
              (row) => OrderingTerm.desc(row.id),
            ])
            ..limit(1))
          .getSingleOrNull();
  return trigger.shouldExpire(
        currentLastUserMessageId: latestUser?.id,
        currentLastUserMessageAt: latestUser == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(latestUser.createdAt),
        isChatActive: false,
      )
      ? 'trigger_context_expired'
      : null;
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
    final existing = await MessageRepository(
      await _taskDatabase(),
    ).getById(messageId ?? backgroundTriggerMessageId(triggerId));
    return existing != null &&
        existing.conversationId == conversationId &&
        existing.deletedAt == null &&
        existing.replacedBy == null;
  } catch (e) {
    print('[Background] Failed to check delivered message: $e');
    rethrow;
  }
}

Future<bool> _isTriggerDelivered(
  String conversationId,
  String triggerId, {
  String? messageId,
}) async {
  if (await _isTriggerMessageDelivered(
    conversationId,
    triggerId,
    messageId: messageId,
  )) {
    return true;
  }
  final trigger = await _loadBackgroundTrigger(triggerId, conversationId);
  return trigger?.action == ProactiveAction.callUser &&
      await ProactiveCallLedger(await _taskDatabase()).isConfirmed(triggerId);
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
  final settings = AutoReplySettings.fromJson(
    await _loadAutoReplySettingsMap(),
  ).forContact(convId);
  final ledger = ProactiveCallLedger(await _taskDatabase());
  final String? blocked = !settings.allowProactiveCalls
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
  final handedOff = !(await ProactiveOwnership.load()).owns(convId);
  if (handedOff) {
    await _releaseTriggerExecutionClaim(triggerId, claimToken);
  }
  if (handedOff ||
      !await _withClaimStore(
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
  final beforeConfirm =
      Zone.current[#beforeBackgroundCallConfirm] as Future<void> Function()?;
  await beforeConfirm?.call();
  final String? invalid;
  try {
    invalid = await cloudLocalWrite(() async {
      final db = await _taskDatabase();
      var reason = await _backgroundDeliveryInvalidReason(
        db,
        conversationId: convId,
        triggerId: triggerId,
      );
      if (reason != null) return reason;
      await ledger.confirm(triggerId);
      reason = await _backgroundDeliveryInvalidReason(
        db,
        conversationId: convId,
        triggerId: triggerId,
      );
      return reason;
    });
  } catch (_) {
    if (!await ledger.isConfirmed(triggerId)) {
      await ledger.release(triggerId);
      await _withClaimStore(
        (store) => store.abortDelivery(triggerId, claimToken),
        fallback: null,
        what: 'abort failed call confirmation',
      );
    }
    rethrow;
  }
  if (invalid != null) {
    await ledger.release(triggerId);
    await _withClaimStore(
      (store) => store.abortDelivery(triggerId, claimToken),
      fallback: null,
      what: 'cancel invalid call',
    );
    if (invalid != 'other_device') {
      await _markTriggerTerminal(triggerId, status: 'expired', reason: invalid);
    }
    return true;
  }
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
  await cloudLocalWrite(
    () => _advanceConversationProactiveStateAfterBackgroundSend(
      triggerId: triggerId,
      conversationId: conversationId,
    ),
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
        delay:
            startedAt
                .add(AutoReplyClaimStore.lease)
                .difference(DateTime.now()) +
            const Duration(minutes: 1),
      );
      print(
        '[Background] Delivery in progress elsewhere, rescheduled past '
        'its lease. triggerId=$triggerId',
      );
      return false;
    case AutoReplyClaimDelivered(:final messageId):
      final delivered = await _isTriggerDelivered(
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
        message: delivered ? '后台主动回复上次送达后中断，补记为已送达' : '后台主动回复上次开始送达后中断，不重试',
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
        delay:
            leaseEndsAt.difference(DateTime.now()) + const Duration(minutes: 1),
      );
      print(
        '[Background] Trigger claimed elsewhere, rescheduled past lease. '
        'triggerId=$triggerId',
      );
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
  required String triggerId,
}) async {
  try {
    final db = await _taskDatabase();
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);

    // 消息、会话摘要与未读数同一事务写入：有消息就一定有摘要和未读，
    // 崩溃恢复只需看消息是否存在。
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawPayload = {
      ...payload.rawPayload,
      'bg_origin_device_id': await MediaStore.localDeviceId,
    };
    final beforePersist =
        Zone.current[_beforeBackgroundPersistKey] as Future<void> Function()?;
    await beforePersist?.call();
    final persisted = await db.transaction(() async {
      // Check after all asynchronous preparation, under the same transaction
      // that commits the message. A synced delete must win over delivery.
      final conv = await convRepo.getById(convId);
      if (conv == null || conv.deletedAt != null) {
        print('[Background] Conversation missing or deleted: $convId');
        return false;
      }
      if (!await _isBackgroundDeliveryCurrent(
        db,
        conversationId: convId,
        triggerId: triggerId,
      )) {
        return false;
      }
      final existing = await msgRepo.getById(messageId);
      if (existing != null) {
        return existing.conversationId == convId &&
            existing.deletedAt == null &&
            existing.replacedBy == null;
      }
      await msgRepo.insert(
        MessagesCompanion(
          id: Value(messageId),
          conversationId: Value(convId),
          role: const Value('assistant'),
          content: Value(payload.rawText),
          status: const Value('sent'),
          createdAt: Value(now),
          rawPayload: Value(jsonEncode(rawPayload)),
        ),
      );
      await convRepo.updateSummary(convId, payload.displayText, now);
      await db.customUpdate(
        'UPDATE conversations SET unread_count = unread_count + 1 WHERE id = ?',
        variables: [Variable.withString(convId)],
        updates: {db.conversations},
      );
      return true;
    });

    if (persisted) {
      print('[Background] Message saved to SQLite.');
    }
    return persisted;
  } catch (e) {
    print('[Background] SQLite Error: $e');
    rethrow;
  }
}

Future<String?> _loadTriggerTitle(
  String triggerId,
  String conversationId,
) async {
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
  String triggerId,
  String conversationId,
) async {
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
    rethrow;
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
      final isActive =
          status == 'created' ||
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
    rethrow;
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
      final isActive =
          current == 'created' ||
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
      await saveCloudPreference(prefs, _triggerStoreKey, jsonEncode(updated));
    }
  } catch (e) {
    print('[Background] Failed to mark trigger $status: $e');
    rethrow;
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final states = Map<String, ConversationProactiveState>.of(
      await storage.loadStates(),
    );
    final current =
        states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    final trigger = await _loadBackgroundTrigger(triggerId, conversationId);
    final db = await _taskDatabase();
    final user =
        await (db.select(db.messages)
              ..where(
                (row) =>
                    row.conversationId.equals(conversationId) &
                    row.role.equals('user') &
                    row.deletedAt.isNull() &
                    row.replacedBy.isNull(),
              )
              ..orderBy([
                (row) => OrderingTerm.desc(row.createdAt),
                (row) => OrderingTerm.desc(row.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    final userAt = user == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(user.createdAt);
    final contextChanged =
        trigger == null ||
        (trigger.contextLastUserMessageId != null
            ? trigger.contextLastUserMessageId != user?.id
            : (trigger.contextLastUserMessageAt == null
                  ? user != null
                  : userAt == null ||
                        userAt.isAfter(trigger.contextLastUserMessageAt!)));
    final next = contextChanged
        ? current.markUserMessage(
            messageId: user?.id,
            occurredAt: userAt ?? DateTime.now(),
          )
        : current
              .clearPendingAutoTrigger(triggerId: triggerId)
              .afterSuccessfulAutoTriggerSend(occurredAt: DateTime.now());
    states[conversationId] = next;
    await storage.saveStates(states);
  } catch (e) {
    print('[Background] Failed to advance proactive state: $e');
    rethrow;
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
    rethrow;
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
