import 'dart:async';

import 'package:aicove_flutter/src/core/services/android_keep_alive_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'consumePendingAlarmSlots'
          ? ['analyzer', 'trigger']
          : null;
    });
  });
  tearDown(() {
    AndroidKeepAliveManager.setProactiveAlarmHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  Future<Object?> fire(String slot) async {
    final reply = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall('onProactiveAlarmFired', {'slot': slot}),
      ),
      (data) {
        try {
          reply.complete(data == null ? null : codec.decodeEnvelope(data));
        } catch (error, stack) {
          reply.completeError(error, stack);
        }
      },
    );
    return reply.future;
  }

  test('alarm methods preserve slot names and epoch milliseconds', () async {
    await AndroidKeepAliveManager.scheduleProactiveAlarm(
      slot: 'analyzer',
      fireAt: DateTime.fromMillisecondsSinceEpoch(1800000000123),
      exact: true,
    );
    await AndroidKeepAliveManager.cancelProactiveAlarm('trigger');
    expect(await AndroidKeepAliveManager.consumePendingAlarmSlots(), [
      'analyzer',
      'trigger',
    ]);
    await AndroidKeepAliveManager.completeHeadlessAlarmRun();
    expect(calls.map((call) => call.method), [
      'scheduleProactiveAlarm',
      'cancelProactiveAlarm',
      'consumePendingAlarmSlots',
      'completeHeadlessAlarmRun',
    ]);
    expect(calls.first.arguments, {
      'slot': 'analyzer',
      'fireAtMillis': 1800000000123,
      'exact': true,
    });
    expect(calls[1].arguments, {'slot': 'trigger'});
  });
  test('native callback awaits handler work and serializes slots', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    final seen = <String>[];
    AndroidKeepAliveManager.setProactiveAlarmHandler((slot) async {
      seen.add(slot);
      if (slot == 'analyzer') {
        entered.complete();
        await finish.future;
      }
    });
    var returned = false;
    final analyzer = fire('analyzer').then((_) => returned = true);
    await entered.future;
    final trigger = fire('trigger');
    await Future<void>.delayed(Duration.zero);
    expect(returned, isFalse);
    expect(seen, ['analyzer']);
    finish.complete();
    await Future.wait([analyzer, trigger]);
    expect(returned, isTrue);
    expect(seen, ['analyzer', 'trigger']);
  });
  test('missing plugin gracefully skips new alarm methods', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await AndroidKeepAliveManager.scheduleProactiveAlarm(
      slot: 'trigger',
      fireAt: DateTime.now(),
      exact: false,
    );
    await AndroidKeepAliveManager.cancelProactiveAlarm('analyzer');
    expect(await AndroidKeepAliveManager.consumePendingAlarmSlots(), isEmpty);
    await AndroidKeepAliveManager.completeHeadlessAlarmRun();
  });
  test('unsupported host skips native alarm methods', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await AndroidKeepAliveManager.scheduleProactiveAlarm(
      slot: 'trigger',
      fireAt: DateTime.now(),
      exact: false,
    );
    await AndroidKeepAliveManager.cancelProactiveAlarm('analyzer');
    expect(await AndroidKeepAliveManager.consumePendingAlarmSlots(), isEmpty);
    await AndroidKeepAliveManager.completeHeadlessAlarmRun();
    expect(calls, isEmpty);
  });
}
