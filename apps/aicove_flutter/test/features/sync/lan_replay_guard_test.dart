import 'package:aicove_flutter/src/features/sync/data/lan_replay_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bulk histories stay bounded without evicting protected requests', () {
    var now = 0;
    final guard = LanReplayGuard(microseconds: () => now);
    for (var i = 0; i < 100000; i++) {
      expect(guard.accept('request-$i'), true);
    }
    expect(guard.atCapacity, true);
    expect(guard.accept('overflow'), false);
    expect(guard.accept('request-0'), false);
    expect(guard.accept('request-99999'), false);
    now = const Duration(minutes: 10).inMicroseconds + 1;
    expect(guard.atCapacity, false);
    expect(guard.accept('request-0'), true);
  });

  test('expiry preserves the exact lifetime boundary and insertion order', () {
    var now = 0;
    final guard = LanReplayGuard(
      capacity: 2,
      lifetime: const Duration(microseconds: 10),
      microseconds: () => now,
    );
    expect(guard.accept('first'), true);
    now = 1;
    expect(guard.accept('second'), true);
    now = 10;
    expect(guard.accept('first'), false);
    expect(guard.accept('third'), false);
    now = 11;
    expect(guard.atCapacity, false);
    expect(guard.accept('third'), true);
    expect(guard.accept('second'), false);
    now = 12;
    expect(guard.accept('second'), true);
    expect(guard.accept('third'), false);
  });

  test('invalid resource bounds are rejected', () {
    expect(() => LanReplayGuard(capacity: 0), throwsArgumentError);
    expect(() => LanReplayGuard(lifetime: Duration.zero), throwsArgumentError);
  });
}
