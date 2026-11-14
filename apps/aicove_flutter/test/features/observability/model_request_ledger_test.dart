import 'dart:convert';

import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/observability/model_request_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/chat/services/provider_key_failure.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/chat/domain/model_request_error_report.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ledger = ModelRequestLedger();
  setUp(() {
    ModelRequestLedger.useBackgroundLane = false;
    SharedPreferences.setMockInitialValues({'aicove.cloud.device_id': 'local'});
  });
  tearDown(() => ModelRequestLedger.useBackgroundLane = false);
  ModelRunRecord record(
    int i, {
    String device = 'local',
    String status = 'succeeded',
    int seq = 1000,
    int? lease,
    int? time,
  }) {
    final now = time ?? DateTime.now().millisecondsSinceEpoch;
    return ModelRunRecord(
      runId: '$i',
      deviceId: device,
      deviceName: 'device',
      conversationId: 'c',
      purpose: 'chat',
      providerId: 'p',
      model: 'm',
      attempt: 1,
      status: status,
      stageSeq: seq,
      startedAtMs: now + i,
      updatedAtMs: now + i,
      leaseUntilMs: lease ?? now + 180000,
    );
  }

  test('single snapshot field, terminal monotonicity and retention', () async {
    for (var i = 0; i < 85; i++) {
      await ledger.write(record(i));
    }
    await ledger.write(record(84, status: 'running', seq: 1));
    final prefs = await SharedPreferences.getInstance();
    const key = 'aicove.plugins.observability.model_runs.local.v1';
    final decoded = jsonDecode(prefs.getString(key)!) as Map;
    expect(decoded.keys, ['snapshot']);
    expect(cloudPreferenceFields(key, prefs.getString(key)).keys, ['snapshot']);
    final journal =
        jsonDecode(prefs.getString(cloudPreferenceTimesKey)!) as Map;
    expect((journal[key] as Map).keys, ['snapshot']);
    final runs = await ledger.all();
    expect(runs, hasLength(80));
    expect(runs.first.status, 'succeeded');
  });
  test('foreground and background lanes are independently aggregated', () async {
    await ledger.write(record(1));
    ModelRequestLedger.useBackgroundLane = true;
    await ledger.write(record(2));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('aicove.plugins.observability.model_runs.local.v1'), isNotNull);
    expect(prefs.getString('aicove.plugins.observability.model_runs.local.bg.v1'), isNotNull);
    expect((await ledger.all()).map((run) => run.runId), containsAll(['1', '2']));
  });
  test('secrets are redacted and text limited', () {
    final value = sanitizeModelRunError(
      'Bearer abc123 sk-abcdefghijk https://a.test/?api_key=hello&token=secret ${'x' * 300}',
    );
    expect(value, isNot(contains('abc123')));
    expect(value, isNot(contains('sk-abcdefghijk')));
    expect(value, isNot(contains('api_key=hello')));
    expect(value, isNot(contains('token=secret')));
    expect(value.length, lessThanOrEqualTo(240));
  });
  test('remote leases expire', () async {
    final now = DateTime.now();
    final remote = record(
      1,
      device: 'remote',
      status: 'running',
      seq: 1,
      lease: now.millisecondsSinceEpoch + 1000,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'aicove.plugins.observability.model_runs.remote.v1',
      jsonEncode({
        'snapshot': {
          'version': 1,
          'device_id': 'remote',
          'device_name': 'device',
          'updated_at_ms': now.millisecondsSinceEpoch,
          'runs': [remote.toJson()],
        },
      }),
    );
    expect(
      await ledger.activeRemoteRunsForConversation('c', now: now),
      hasLength(1),
    );
    expect(
      await ledger.activeRemoteRunsForConversation(
        'c',
        now: now.add(const Duration(seconds: 1)),
      ),
      isEmpty,
    );
  });
  test('full report includes model runs and round start', () {
    final start = DateTime(2026, 1, 1);
    final log = ModelRequestErrorReport.buildFullLog(
      failedModelName: 'A',
      nextModelName: 'B',
      errorMessage: 'failed',
      roundStartedAt: start,
      failedAt: start,
      logEntries: [],
      modelRuns: [record(1)],
    );
    expect(log, contains('跨端模型请求记录'));
    expect(log, contains('device'));
    expect(log, contains(start.toIso8601String()));
    expect(log, isNot(contains('未记录本轮开始时间')));
  });
  test('scoped executor records running and failed result', () async {
    final config = ApiConfig(
      settings: mapUiModelsToAppSettings({}),
      modelFullId: 'model',
      providerApiBase: '',
      customConfig: const {},
      messages: const [],
    );
    await const ModelRunScope(
      purpose: 'chat',
      conversationId: 'c',
      turnId: 't',
      attempt: 2,
    ).run(
      () => executeWithProviderKeyFailureRecording(
        config: config,
        execute: () async {
          final running = (await ledger.forConversation('c')).single;
          expect(running.status, 'running');
          expect(running.stageSeq, 1);
          return const ApiCallResult(
            status: ApiRunStatus.failed,
            replyText: '',
            processedText: '',
            pluginEvents: [],
            toolResults: [],
          );
        },
      ),
    );
    final ended = (await ledger.forConversation('c')).single;
    expect(ended.status, 'failed');
    expect(ended.stageSeq, 1000);
    expect(ended.attempt, 2);
    expect(ended.turnId, 't');
  });
}
