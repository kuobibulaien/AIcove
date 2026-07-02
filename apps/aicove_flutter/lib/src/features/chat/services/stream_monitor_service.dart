library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';

enum StreamFailureReason {
  unsupportedProvider('unsupported_provider'),
  missingApiKey('missing_api_key'),
  unauthorized('unauthorized'),
  timeout('timeout'),
  network('network'),
  parse('parse'),
  unknown('unknown');

  const StreamFailureReason(this.value);
  final String value;

  static StreamFailureReason fromValue(String? value) {
    for (final item in StreamFailureReason.values) {
      if (item.value == value) return item;
    }
    return StreamFailureReason.unknown;
  }
}

@immutable
class StreamMonitorSnapshot {
  const StreamMonitorSnapshot({
    required this.attemptCount,
    required this.successCount,
    required this.fallbackCount,
    required this.failureCounts,
    this.lastFailureAt,
    this.lastFailureReason,
    this.lastFailureError,
    this.lastModelFullId,
  });

  const StreamMonitorSnapshot.initial()
      : attemptCount = 0,
        successCount = 0,
        fallbackCount = 0,
        failureCounts = const <String, int>{},
        lastFailureAt = null,
        lastFailureReason = null,
        lastFailureError = null,
        lastModelFullId = null;

  final int attemptCount;
  final int successCount;
  final int fallbackCount;
  final Map<String, int> failureCounts;
  final DateTime? lastFailureAt;
  final StreamFailureReason? lastFailureReason;
  final String? lastFailureError;
  final String? lastModelFullId;

  int get failCount =>
      failureCounts.values.fold<int>(0, (sum, item) => sum + item);

  double get successRate {
    if (attemptCount <= 0) return 1;
    return successCount / attemptCount;
  }

  StreamMonitorSnapshot copyWith({
    int? attemptCount,
    int? successCount,
    int? fallbackCount,
    Map<String, int>? failureCounts,
    DateTime? lastFailureAt,
    StreamFailureReason? lastFailureReason,
    String? lastFailureError,
    String? lastModelFullId,
    bool clearFailure = false,
  }) {
    return StreamMonitorSnapshot(
      attemptCount: attemptCount ?? this.attemptCount,
      successCount: successCount ?? this.successCount,
      fallbackCount: fallbackCount ?? this.fallbackCount,
      failureCounts: failureCounts ?? this.failureCounts,
      lastFailureAt:
          clearFailure ? null : (lastFailureAt ?? this.lastFailureAt),
      lastFailureReason:
          clearFailure ? null : (lastFailureReason ?? this.lastFailureReason),
      lastFailureError:
          clearFailure ? null : (lastFailureError ?? this.lastFailureError),
      lastModelFullId: lastModelFullId ?? this.lastModelFullId,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'attemptCount': attemptCount,
      'successCount': successCount,
      'fallbackCount': fallbackCount,
      'failureCounts': failureCounts,
      'lastFailureAt': lastFailureAt?.toIso8601String(),
      'lastFailureReason': lastFailureReason?.value,
      'lastFailureError': lastFailureError,
      'lastModelFullId': lastModelFullId,
    };
  }

  factory StreamMonitorSnapshot.fromJson(Map<String, dynamic> json) {
    final rawFailure = json['failureCounts'];
    final failure = <String, int>{};
    if (rawFailure is Map) {
      rawFailure.forEach((key, value) {
        final count = value is num ? value.toInt() : 0;
        failure[key.toString()] = count < 0 ? 0 : count;
      });
    }

    DateTime? lastFailureAt;
    final rawLastFailureAt = json['lastFailureAt']?.toString();
    if (rawLastFailureAt != null && rawLastFailureAt.isNotEmpty) {
      lastFailureAt = DateTime.tryParse(rawLastFailureAt);
    }

    return StreamMonitorSnapshot(
      attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
      successCount: (json['successCount'] as num?)?.toInt() ?? 0,
      fallbackCount: (json['fallbackCount'] as num?)?.toInt() ?? 0,
      failureCounts: failure,
      lastFailureAt: lastFailureAt,
      lastFailureReason:
          StreamFailureReason.fromValue(json['lastFailureReason']?.toString()),
      lastFailureError: json['lastFailureError']?.toString(),
      lastModelFullId: json['lastModelFullId']?.toString(),
    );
  }
}

class StreamMonitorService {
  static const String _prefsKey = 'stream_monitor_snapshot_v1';
  static final ValueNotifier<StreamMonitorSnapshot> snapshot =
      ValueNotifier<StreamMonitorSnapshot>(
          const StreamMonitorSnapshot.initial());

  static bool _loaded = false;
  static bool _loading = false;

  static Future<void> ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = _decodeJsonMap(raw);
        if (parsed != null) {
          snapshot.value = StreamMonitorSnapshot.fromJson(parsed);
        }
      }
    } catch (_) {
      // 忽略读取失败，继续使用内存默认值
    } finally {
      _loaded = true;
      _loading = false;
    }
  }

  static Future<void> reset() async {
    await ensureLoaded();
    snapshot.value = const StreamMonitorSnapshot.initial();
    await _persist();
    AppLogger.info('StreamMonitor', '流式监控已重置');
  }

  static Future<void> recordAttempt({
    required String modelFullId,
    int? round,
  }) async {
    await ensureLoaded();
    final current = snapshot.value;
    final next = current.copyWith(
      attemptCount: current.attemptCount + 1,
      lastModelFullId: modelFullId,
    );
    snapshot.value = next;
    await _persist();
    AppLogger.info(
      'StreamMonitor',
      '流式请求尝试',
      metadata: {
        'round': round,
        'model': modelFullId,
        'attemptCount': next.attemptCount,
      },
    );
  }

  static Future<void> recordSuccess({
    required String modelFullId,
    int? round,
  }) async {
    await ensureLoaded();
    final current = snapshot.value;
    final next = current.copyWith(
      successCount: current.successCount + 1,
      lastModelFullId: modelFullId,
    );
    snapshot.value = next;
    await _persist();
    AppLogger.info(
      'StreamMonitor',
      '流式请求成功',
      metadata: {
        'round': round,
        'model': modelFullId,
        'successCount': next.successCount,
        'successRate': next.successRate.toStringAsFixed(4),
      },
    );
  }

  static Future<void> recordFallback({
    required String modelFullId,
    required Object error,
    required StreamFailureReason reason,
    int? round,
  }) async {
    await ensureLoaded();

    final current = snapshot.value;
    final failureCounts = <String, int>{...current.failureCounts};
    failureCounts[reason.value] = (failureCounts[reason.value] ?? 0) + 1;

    final next = current.copyWith(
      fallbackCount: current.fallbackCount + 1,
      failureCounts: failureCounts,
      lastFailureAt: DateTime.now(),
      lastFailureReason: reason,
      lastFailureError: error.toString(),
      lastModelFullId: modelFullId,
    );
    snapshot.value = next;
    await _persist();
    AppLogger.warning(
      'StreamMonitor',
      '流式请求回退',
      metadata: {
        'round': round,
        'model': modelFullId,
        'reason': reason.value,
        'error': error.toString(),
        'fallbackCount': next.fallbackCount,
        'failureCountForReason': failureCounts[reason.value],
      },
    );
  }

  static StreamFailureReason classifyError(Object error) {
    if (error is UnsupportedError) {
      return StreamFailureReason.unsupportedProvider;
    }
    if (error is TimeoutException) {
      return StreamFailureReason.timeout;
    }

    final text = error.toString().toLowerCase();
    if (text.contains('missing providerapikey')) {
      return StreamFailureReason.missingApiKey;
    }
    if (text.contains('http 401') ||
        text.contains('http 403') ||
        text.contains('unauthorized') ||
        text.contains('invalid api key')) {
      return StreamFailureReason.unauthorized;
    }
    if (text.contains('socketexception') ||
        text.contains('connection') ||
        text.contains('network')) {
      return StreamFailureReason.network;
    }
    if (text.contains('formatexception') ||
        text.contains('json') ||
        text.contains('parse')) {
      return StreamFailureReason.parse;
    }
    return StreamFailureReason.unknown;
  }

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _encodeJsonMap(snapshot.value.toJson()));
    } catch (_) {
      // 持久化失败不影响主流程
    }
  }
}

Map<String, dynamic>? _decodeJsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  } catch (_) {
    return null;
  }
}

String _encodeJsonMap(Map<String, dynamic> data) => jsonEncode(data);
