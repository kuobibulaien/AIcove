import 'dart:async';

import 'package:aicove_flutter/src/features/sync/data/lan_discovery.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fr.skyost.bonsoir');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late BonjourLanDiscovery discovery;
  late List<String> calls;
  late Future<Object?> Function(MethodCall) respond;

  setUp(() {
    discovery = BonjourLanDiscovery();
    calls = [];
    respond = (_) async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method.endsWith('.initialize')) {
        final kind = call.method.split('.').first;
        final id = (call.arguments as Map)['id'];
        messenger.setMockMethodCallHandler(
          MethodChannel('fr.skyost.bonsoir.$kind.$id'),
          (_) async => null,
        );
      }
      return respond(call);
    });
  });
  tearDown(() async {
    await discovery.stop();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'a lost start reply times out, releases broadcast, and permits retry',
    () async {
      final pending = Completer<Object?>();
      respond = (call) async {
        if (call.method == 'broadcast.start') return pending.future;
        if (call.method == 'broadcast.stop' && !pending.isCompleted) {
          pending.completeError(PlatformException(code: 'broadcastError'));
        }
        return true;
      };
      await expectLater(
        discovery.start('device', 12345, (_, _) {}),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, [
        'broadcast.initialize',
        'broadcast.start',
        'broadcast.stop',
      ]);
      expect(discovery.isRunning, isFalse);
      respond = (_) async => true;
      await discovery.start('device', 12345, (_, _) {});
      expect(discovery.isRunning, isTrue);
      await discovery.stop();
      expect(calls.sublist(calls.length - 2), [
        'discovery.stop',
        'broadcast.stop',
      ]);
    },
  );

  test(
    'native registration error cleans up without starting discovery',
    () async {
      respond = (call) async {
        if (call.method == 'broadcast.start') {
          throw PlatformException(code: 'broadcastError', details: -65568);
        }
        return true;
      };
      await expectLater(
        discovery.start('device', 12345, (_, _) {}),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.last, 'broadcast.stop');
      expect(calls, isNot(contains('discovery.start')));
      expect(discovery.isRunning, isFalse);
    },
  );

  test('replacement waits for the old broadcast stop to complete', () async {
    await discovery.start('device', 12345, (_, _) {});
    final stopping = Completer<Object?>();
    final stopEntered = Completer<void>();
    respond = (call) async {
      if (call.method == 'broadcast.stop') {
        stopEntered.complete();
        return stopping.future;
      }
      return true;
    };
    final next = discovery.start('device', 23456, (_, _) {});
    final finalStop = discovery.stop();
    await stopEntered.future;
    expect(calls.where((call) => call == 'broadcast.initialize').length, 1);
    respond = (_) async => true;
    stopping.complete(true);
    await next;
    await finalStop;
    expect(calls.where((call) => call == 'broadcast.initialize').length, 2);
    expect(discovery.isRunning, isFalse);
  });
}
