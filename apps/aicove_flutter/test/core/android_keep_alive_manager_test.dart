import 'dart:async';

import 'package:aicove_flutter/src/core/services/android_keep_alive_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<bool> transitions;
  late bool active;
  late bool ready;
  late String error;
  late int statusReads;
  Future<Object?> Function(MethodCall)? intercept;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    transitions = [];
    active = false;
    ready = true;
    error = '';
    statusReads = 0;
    intercept = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (intercept != null) return intercept!(call);
      if (call.method == 'setGenerationActive') {
        active = (call.arguments as Map)['active'] == true;
        transitions.add(active);
        return null;
      }
      if (call.method == 'getStatus') statusReads++;
      return <String, Object>{
        'guardEnabled': false,
        'generationActive': active,
        'serviceRunning': active && ready,
        'generationWakeLockHeld': active && ready,
        'lastStartError': error,
      };
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('acquire waits for foreground service and wake lock', () async {
    ready = false;
    AndroidGenerationKeepAliveLease? lease;
    final pending = AndroidKeepAliveManager.acquireGenerationLease().then(
      (value) => lease = value,
    );
    await Future<void>.delayed(Duration.zero);
    expect(lease, isNull);
    expect(statusReads, 1);
    ready = true;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await pending;
    expect(lease, isNotNull);
    await lease!.release();
    expect(transitions, [true, false]);
  });

  test('concurrent leases only release native state after last task', () async {
    final leases = await Future.wait([
      AndroidKeepAliveManager.acquireGenerationLease(),
      AndroidKeepAliveManager.acquireGenerationLease(),
    ]);
    await leases.first!.release();
    await leases.first!.release();
    expect(transitions, [true, true]);
    await leases.last!.release();
    expect(transitions, [true, true, false]);
  });

  test('native start error is surfaced and queue recovers', () async {
    error = 'start denied';
    await expectLater(
      AndroidKeepAliveManager.acquireGenerationLease(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.message,
          'message',
          'start denied',
        ),
      ),
    );
    expect(transitions, [true, false]);
    error = '';
    final lease = await AndroidKeepAliveManager.acquireGenerationLease();
    await lease!.release();
    expect(transitions, [true, false, true, false]);
  });

  test('readiness timeout cleans up native generation', () async {
    ready = false;
    final pending = expectLater(
      AndroidKeepAliveManager.acquireGenerationLease(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'generation_guard_not_ready',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 7; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    await pending;
    expect(statusReads, 8);
    expect(transitions, [true, false]);
  });

  test('new acquire waits for pending final release', () async {
    final first = await AndroidKeepAliveManager.acquireGenerationLease();
    final stopped = Completer<void>();
    intercept = (call) async {
      if (call.method == 'setGenerationActive') {
        final next = (call.arguments as Map)['active'] == true;
        transitions.add(next);
        if (!next) await stopped.future;
        active = next;
        return null;
      }
      return <String, Object>{
        'generationActive': active,
        'serviceRunning': active,
        'generationWakeLockHeld': active,
      };
    };
    final release = first!.release();
    final next = AndroidKeepAliveManager.acquireGenerationLease();
    await Future<void>.delayed(Duration.zero);
    expect(transitions, [true, false]);
    stopped.complete();
    await release;
    final second = await next;
    expect(active, isTrue);
    expect(transitions, [true, false, true]);
    await second!.release();
  });

  test('channel exception does not poison later acquire', () async {
    intercept = (call) async {
      throw PlatformException(code: 'channel_failed');
    };
    await expectLater(
      AndroidKeepAliveManager.acquireGenerationLease(),
      throwsA(isA<PlatformException>()),
    );
    intercept = null;
    final lease = await AndroidKeepAliveManager.acquireGenerationLease();
    await lease!.release();
    expect(transitions, [true, false]);
  });

  test('disabling persistent guard preserves generation service', () async {
    final lease = await AndroidKeepAliveManager.acquireGenerationLease();
    final status = await AndroidKeepAliveManager.setGuardEnabled(false);
    expect(status!.generationActive, isTrue);
    expect(status.serviceRunning, isTrue);
    expect(statusReads, 1);
    await lease!.release();
  });

  test('non Android does not call native channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(await AndroidKeepAliveManager.acquireGenerationLease(), isNull);
    expect(transitions, isEmpty);
    expect(statusReads, 0);
  });
}
