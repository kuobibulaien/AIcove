import 'dart:async';

/// Serializes publication of settings/files with the sync compare-and-apply
/// section. User edits arriving during a cloud write publish afterwards and are
/// picked up by the next scan. Nested writes remain in the same operation.
///
/// All Zones in this isolate share the queue. Idle tails are cleared before
/// returning to the caller, so a completed fake-async Zone cannot strand the
/// next caller. A reentry token is valid only while its operation holds the
/// lock; detached continuations must queue again after that operation ends.
final Object _cloudWriteZone = Object();
Future<void>? _cloudWriteTail;

class _WriteLease {
  bool active = true;
}

Future<T> cloudLocalWrite<T>(Future<T> Function() operation) async {
  final inherited = Zone.current[_cloudWriteZone] as _WriteLease?;
  if (inherited?.active == true) return operation();
  final previous = _cloudWriteTail;
  final released = Completer<void>();
  _cloudWriteTail = released.future;
  final lease = _WriteLease();
  try {
    if (previous != null) await previous;
    return await runZoned(operation, zoneValues: {_cloudWriteZone: lease});
  } finally {
    lease.active = false;
    if (identical(_cloudWriteTail, released.future)) _cloudWriteTail = null;
    released.complete();
  }
}
