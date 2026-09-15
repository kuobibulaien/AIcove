import 'dart:async';

import '../../../core/sync/cloud_tracking.dart';
import 'cloud_local_store.dart';

/// Committed database edits wake the uploader. Lightweight remote polls keep
/// receiving responsive; periodic full scans also capture settings/file edits.
class CloudSyncScheduler {
  CloudSyncScheduler(this.local, this.run);

  final CloudLocalStore local;
  final Future<void> Function({bool pollOnly}) run;
  StreamSubscription<dynamic>? _changes;
  Timer? _pollTimer;
  Timer? _changeTimer;
  Future<void>? _work;
  bool _closed = false;
  bool _requested = false;
  bool _full = false;
  int _ticks = 0;

  void start() {
    if (_closed || _pollTimer != null) return;
    _changes = local.db.tableUpdates().listen((updates) {
      if (updates.any((update) => cloudTables.containsKey(update.table))) {
        _changeTimer ??= Timer(const Duration(milliseconds: 300), () {
          _changeTimer = null;
          unawaited(_checkCommittedEdits());
        });
      }
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_work != null) return;
      unawaited(synchronize(pollOnly: ++_ticks % 5 != 0));
    });
  }

  Future<void> _checkCommittedEdits() async {
    try {
      final dirty = await local.rows('SELECT 1 FROM cloud_dirty LIMIT 1');
      // Remote applies notify Drift too, but have no locally dirty revision.
      if (!_closed && dirty.isNotEmpty) await synchronize();
    } catch (_) {
      // Closing the database or a transient read failure is retried by polling.
    }
  }

  Future<void> synchronize({bool pollOnly = false}) {
    if (_closed) return _work ?? Future.value();
    _requested = true;
    _full |= !pollOnly;
    return _work ??= _drain().whenComplete(() => _work = null);
  }

  Future<void> _drain() async {
    while (_requested && !_closed) {
      final full = _full;
      _requested = _full = false;
      try {
        await run(pollOnly: !full);
      } catch (_) {
        // The engine reports the error and retains pending work for retry.
      }
    }
  }

  void close() {
    _closed = true;
    _pollTimer?.cancel();
    _changeTimer?.cancel();
    unawaited(_changes?.cancel());
  }
}
