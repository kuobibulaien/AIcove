import 'dart:async';

import 'cloud_local_store.dart';

/// The cloud is the fallback channel; paired devices sync over LAN in real
/// time. Automatic rounds therefore run only a few times a day: when due on
/// launch, on resume, or on a cheap local timer that never touches the
/// network unless a round is due. Manual sync always runs immediately.
class CloudSyncScheduler {
  CloudSyncScheduler(
    this.local,
    this.run, {
    this.interval = const Duration(hours: 8),
    this.retry = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const lastSuccessKey = 'aicove.cloud.last_sync_ms';
  static const lastAttemptKey = 'aicove.cloud.last_attempt_ms';

  final CloudLocalStore local;

  /// Runs one round; returns whether it completed without error.
  final Future<bool> Function() run;
  final Duration interval, retry;
  final DateTime Function() _now;
  Timer? _timer;
  Future<void>? _work;
  bool _closed = false;

  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 30), (_) {
      unawaited(synchronizeIfDue());
    });
    unawaited(synchronizeIfDue());
  }

  bool get due {
    final now = _now().millisecondsSinceEpoch;
    final success = local.preferences.getInt(lastSuccessKey) ?? 0;
    final attempt = local.preferences.getInt(lastAttemptKey) ?? 0;
    return now - success >= interval.inMilliseconds &&
        now - attempt >= retry.inMilliseconds;
  }

  Future<void> synchronizeIfDue() async {
    if (_closed || _work != null || !due) return;
    await synchronize();
  }

  /// Runs a round now (manual sync), joining one already in progress.
  Future<void> synchronize() {
    if (_closed) return _work ?? Future.value();
    return _work ??= _round().whenComplete(() => _work = null);
  }

  Future<void> _round() async {
    await local.preferences.setInt(
      lastAttemptKey,
      _now().millisecondsSinceEpoch,
    );
    var ok = false;
    try {
      ok = await run();
    } catch (_) {
      // The engine reports the error and retains pending work for retry.
    }
    if (ok && !_closed) {
      await local.preferences.setInt(
        lastSuccessKey,
        _now().millisecondsSinceEpoch,
      );
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
