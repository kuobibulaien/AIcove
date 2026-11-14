import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_logger.dart';
import '../../core/media/media_store.dart';
import '../../core/sync/cloud_local_write.dart';
import '../../core/sync/cloud_setting_policy.dart';
import '../chat/domain/model_request_error_report.dart';
import '../sync/data/device_names.dart';

const _prefix = 'aicove.plugins.observability.model_runs.';
const _suffix = '.v1';

class ModelRunRecord {
  const ModelRunRecord({
    required this.runId,
    required this.deviceId,
    required this.deviceName,
    this.conversationId,
    this.turnId,
    required this.purpose,
    required this.providerId,
    required this.model,
    required this.attempt,
    required this.status,
    required this.stageSeq,
    required this.startedAtMs,
    required this.updatedAtMs,
    this.endedAtMs,
    this.durationMs,
    required this.leaseUntilMs,
    this.errorBrief,
  });
  final String runId, deviceId, deviceName, purpose, providerId, model, status;
  final String? conversationId, turnId, errorBrief;
  final int attempt, stageSeq, startedAtMs, updatedAtMs, leaseUntilMs;
  final int? endedAtMs, durationMs;

  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'device_id': deviceId,
    'device_name': deviceName,
    'conversation_id': conversationId,
    'turn_id': turnId,
    'purpose': purpose,
    'provider_id': providerId,
    'model': model,
    'attempt': attempt,
    'status': status,
    'stage_seq': stageSeq,
    'started_at_ms': startedAtMs,
    'updated_at_ms': updatedAtMs,
    'ended_at_ms': endedAtMs,
    'duration_ms': durationMs,
    'lease_until_ms': leaseUntilMs,
    'error_brief': errorBrief == null
        ? null
        : sanitizeModelRunError(errorBrief!),
  };
  factory ModelRunRecord.fromJson(Map<String, dynamic> j) => ModelRunRecord(
    runId: j['run_id'] as String,
    deviceId: j['device_id'] as String,
    deviceName: j['device_name'] as String,
    conversationId: j['conversation_id'] as String?,
    turnId: j['turn_id'] as String?,
    purpose: j['purpose'] as String,
    providerId: j['provider_id'] as String,
    model: j['model'] as String,
    attempt: j['attempt'] as int,
    status: j['status'] as String,
    stageSeq: j['stage_seq'] as int,
    startedAtMs: j['started_at_ms'] as int,
    updatedAtMs: j['updated_at_ms'] as int,
    endedAtMs: j['ended_at_ms'] as int?,
    durationMs: j['duration_ms'] as int?,
    leaseUntilMs: j['lease_until_ms'] as int,
    errorBrief: j['error_brief'] == null
        ? null
        : sanitizeModelRunError(j['error_brief'] as String),
  );
  ModelRunRecord advance(String status, int now, {String? error}) =>
      ModelRunRecord(
        runId: runId,
        deviceId: deviceId,
        deviceName: deviceName,
        conversationId: conversationId,
        turnId: turnId,
        purpose: purpose,
        providerId: providerId,
        model: model,
        attempt: attempt,
        status: status,
        stageSeq: status == 'running' ? (stageSeq + 1).clamp(1, 999) : 1000,
        startedAtMs: startedAtMs,
        updatedAtMs: now,
        endedAtMs: status == 'running' ? null : now,
        durationMs: status == 'running' ? null : now - startedAtMs,
        leaseUntilMs: now + 180000,
        errorBrief: error == null ? null : sanitizeModelRunError(error),
      );
}

String sanitizeModelRunError(String error) {
  var value = ModelRequestErrorReport.summarize(error);
  value = value.replaceAll(
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
    'Bearer [redacted]',
  );
  value = value.replaceAll(
    RegExp(r'sk-[A-Za-z0-9_-]{8,}', caseSensitive: false),
    '[redacted]',
  );
  value = value.replaceAllMapped(
    RegExp(
      r'((?:api_key|apikey|key|token|secret)=)[^&\s]+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[redacted]',
  );
  final http = RegExp(r'^HTTP \d{3}').firstMatch(value);
  if (http != null) return http.group(0)!;
  for (final prefix in [
    '请求超时',
    'TLS 握手失败',
    '网络连接失败',
    '鉴权失败',
    '账户余额不足',
    '上下文超出模型上限',
  ]) {
    if (value.startsWith(prefix)) return prefix;
  }
  return '模型请求失败';
}

class ModelRunScope {
  const ModelRunScope({
    required this.purpose,
    this.conversationId,
    this.turnId,
    this.attempt = 1,
  });
  final String purpose;
  final String? conversationId, turnId;
  final int attempt;
  static final Object _key = Object();
  static ModelRunScope? get current => Zone.current[_key] as ModelRunScope?;
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
}

class ModelRequestLedger {
  const ModelRequestLedger();
  static const instance = ModelRequestLedger();

  /// Isolate-local lane, set at the WorkManager entry point.
  static bool useBackgroundLane = false;
  Future<ModelRunRecord> begin(
    ModelRunScope scope,
    String providerId,
    String model,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final id = await MediaStore.localDeviceId;
    final now = DateTime.now().millisecondsSinceEpoch;
    final record = ModelRunRecord(
      runId: const Uuid().v4(),
      deviceId: id,
      deviceName: await ownDeviceName(prefs),
      conversationId: scope.conversationId,
      turnId: scope.turnId,
      purpose: scope.purpose,
      providerId: providerId,
      model: model,
      attempt: scope.attempt,
      status: 'running',
      stageSeq: 1,
      startedAtMs: now,
      updatedAtMs: now,
      leaseUntilMs: now + 180000,
    );
    await write(record);
    return record;
  }

  Future<void> write(ModelRunRecord record) async {
    try {
      if (record.deviceId != await MediaStore.localDeviceId) {
        throw StateError('Cannot write another device ledger');
      }
      await cloudLocalWrite(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final lane = useBackgroundLane ? '.bg' : '';
        final key = '$_prefix${record.deviceId}$lane$_suffix';
        final runs = {for (final r in _parse(prefs.getString(key))) r.runId: r};
        final old = runs[record.runId];
        if (old == null ||
            record.stageSeq > old.stageSeq ||
            (record.stageSeq == old.stageSeq &&
                record.updatedAtMs > old.updatedAtMs)) {
          runs[record.runId] = record;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final active = runs.values
            .where((r) => r.status == 'running' && r.leaseUntilMs > now)
            .toList();
        final ended =
            runs.values
                .where(
                  (r) =>
                      r.status != 'running' &&
                      (r.endedAtMs ?? r.startedAtMs) >=
                          now - const Duration(days: 7).inMilliseconds,
                )
                .toList()
              ..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
        final saved = await saveCloudPreference(
          prefs,
          key,
          canonicalSettingJson({
            'snapshot': {
              'version': 1,
              'device_id': record.deviceId,
              'device_name': record.deviceName,
              'updated_at_ms': now,
              'runs': [
                ...active,
                ...ended.take(80),
              ].map((r) => r.toJson()).toList(),
            },
          }),
        );
        if (!saved) throw StateError('Could not save model request ledger');
        // The generic settings writer creates a synthetic null `value`
        // tombstone on the first JSON write. This key has only `snapshot`.
        final journal = preferenceTimeJournal(prefs);
        final clocks = journal[key];
        if (clocks is Map && clocks.containsKey('value')) {
          clocks.remove('value');
          await prefs.setString(cloudPreferenceTimesKey, jsonEncode(journal));
        }
      });
    } catch (e) {
      AppLogger.warning(
        'ModelRequestLedger',
        '写入模型请求记录失败',
        metadata: {'error': '$e'},
      );
    }
  }

  List<ModelRunRecord> _parse(String? raw) {
    if (raw == null) return [];
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final snapshot = json['snapshot'] as Map<String, dynamic>;
      return (snapshot['runs'] as List)
          .map(
            (r) => ModelRunRecord.fromJson(Map<String, dynamic>.from(r as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<ModelRunRecord>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final result = [
        for (final key in prefs.getKeys())
          if (key.startsWith(_prefix) && key.endsWith(_suffix))
            ..._parse(prefs.getString(key)),
      ];
      result.sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
      return result;
    } catch (error) {
      AppLogger.warning(
        'ModelRequestLedger',
        '读取模型请求记录失败',
        metadata: {'error': '$error'},
      );
      return [];
    }
  }

  Future<List<ModelRunRecord>> forConversation(String id) async =>
      (await all()).where((r) => r.conversationId == id).toList();
  Future<List<ModelRunRecord>> activeRemoteRunsForConversation(
    String id, {
    DateTime? now,
  }) async {
    String local;
    try {
      local = await MediaStore.localDeviceId;
    } catch (error) {
      AppLogger.warning(
        'ModelRequestLedger',
        '读取本机设备失败',
        metadata: {'error': '$error'},
      );
      return [];
    }
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return (await forConversation(id))
        .where(
          (r) =>
              r.deviceId != local &&
              r.status == 'running' &&
              time < r.leaseUntilMs,
        )
        .toList();
  }
}

final modelRequestLedgerProvider = Provider<ModelRequestLedger>(
  (ref) => ModelRequestLedger.instance,
);
final modelRunsProvider = StreamProvider<List<ModelRunRecord>>((ref) async* {
  final ledger = ref.watch(modelRequestLedgerProvider);
  final changes = StreamController<void>();
  final subscription = externalSyncChanges.listen((key) {
    if (key == null || key.startsWith(_prefix)) changes.add(null);
  });
  try {
    yield await ledger.all();
    await for (final _ in changes.stream) {
      yield await ledger.all();
    }
  } finally {
    await subscription.cancel();
    await changes.close();
  }
});

final modelRunsForConversationProvider =
    Provider.family<List<ModelRunRecord>, String>(
      (ref, id) =>
          ref
              .watch(modelRunsProvider)
              .valueOrNull
              ?.where((run) => run.conversationId == id)
              .toList() ??
          const [],
    );
