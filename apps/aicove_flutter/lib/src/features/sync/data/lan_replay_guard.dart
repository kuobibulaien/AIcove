import 'dart:collection';

/// Bounded, insertion-ordered replay history for authenticated LAN requests.
/// A full history must reject new requests, not evict still-protected nonces.
class LanReplayGuard {
  LanReplayGuard({
    this.capacity = 100000,
    this.lifetime = const Duration(minutes: 10),
    int Function()? microseconds,
  }) : _microseconds = microseconds ?? _monotonicClock() {
    if (capacity < 1 || lifetime.inMicroseconds < 1) {
      throw ArgumentError('Replay capacity and lifetime must be positive');
    }
  }

  final int capacity;
  final Duration lifetime;
  final int Function() _microseconds;
  final _accepted = <String, int>{};
  final _order = Queue<String>();

  static int Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds;
  }

  void _expire() {
    final cutoff = _microseconds() - lifetime.inMicroseconds;
    // Monotonic insertion times allow pruning only the expired prefix.
    while (_order.isNotEmpty && _accepted[_order.first]! < cutoff) {
      _accepted.remove(_order.removeFirst());
    }
  }

  bool get atCapacity {
    _expire();
    return _accepted.length >= capacity;
  }

  bool accept(String id) {
    _expire();
    if (_accepted.containsKey(id) || _accepted.length >= capacity) return false;
    _accepted[id] = _microseconds();
    _order.addLast(id);
    return true;
  }
}
