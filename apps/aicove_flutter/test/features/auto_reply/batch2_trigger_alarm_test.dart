import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_controller.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_owner_device.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Generator extends ProactiveReplyGenerator {
  _Generator(super.ref, this.run);
  final Future<String> Function() run;
  @override
  Future<String> generate({
    required Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) => run();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
  const workChannel = MethodChannel(
    'be.tramckrijte.workmanager/foreground_channel_work_manager',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final previousPaths = PathProviderPlatform.instance;
  late Directory directory;
  late SegmentedChatFixture fixture;
  late List<MethodCall> alarms;
  late List<List<String>> pendingSlots;
  late Completer<void> generationEntered;
  late Completer<void> generationFinish;
  late int generations;
  Future<void> Function(MethodCall call)? beforeAlarm;

  Future<void> waitFor(bool Function() condition) async {
    for (var attempt = 0; attempt < 300; attempt++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for alarm synchronization');
  }

  Map lastArguments() => alarms.last.arguments as Map;

  setUpAll(() async {
    directory = await (await Directory(
      'build/batch2_trigger_alarm',
    ).create(recursive: true)).createTemp();
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    alarms = [];
    pendingSlots = [];
    beforeAlarm = null;
    generations = 0;
    generationEntered = Completer<void>();
    generationFinish = Completer<void>();
    messenger.setMockMethodCallHandler(workChannel, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scheduleProactiveAlarm' ||
          call.method == 'cancelProactiveAlarm') {
        if ((call.arguments as Map)['slot'] == 'trigger') {
          await beforeAlarm?.call(call);
          alarms.add(call);
        }
      }
      if (call.method == 'consumePendingAlarmSlots') {
        return pendingSlots.isEmpty ? <String>[] : pendingSlots.removeAt(0);
      }
      if (call.method == 'getStatus' || call.method == 'setGuardEnabled') {
        return <String, Object>{
          'guardEnabled': true,
          'generationActive': true,
          'serviceRunning': true,
          'generationWakeLockHeld': true,
        };
      }
      return null;
    });
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      enabledPlugins: ['trigger'],
      settings: segmentedProbeSettings.copyWith(
        autoReplySettings: const AutoReplySettings(quietHoursEnabled: false),
      ),
      extraOverrides: [
        proactiveReplyGeneratorProvider.overrideWith(
          (ref) => _Generator(ref, () async {
            generations++;
            if (!generationEntered.isCompleted) generationEntered.complete();
            await generationFinish.future;
            return '主动问候 $generations';
          }),
        ),
      ],
    );
    await fixture.container.read(autoReplyTriggersProvider.future);
    await waitFor(() => alarms.isNotEmpty);
    alarms.clear();
  });
  tearDown(() async {
    if (!generationFinish.isCompleted) generationFinish.complete();
    await fixture.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(workChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  AutoReplyTriggerController controller() =>
      fixture.container.read(autoReplyTriggersProvider.notifier);

  Future<AutoReplyTrigger> create(DateTime at, {bool exact = false}) =>
      controller().createTrigger(
        title: '提醒',
        type: AutoReplyTriggerType.fixed,
        nextFireAt: at,
        allowNight: true,
        requireExact: exact,
        delayMinutes: 0,
        conversationId: fixture.conversation.id,
      );

  test(
    'create, pause, resume, edit, delete synchronize the earliest slot',
    () async {
      final early = DateTime.now().add(const Duration(hours: 1));
      final late = early.add(const Duration(hours: 1));
      final first = await create(early, exact: true);
      await create(late);
      await waitFor(
        () =>
            alarms.isNotEmpty &&
            lastArguments()['fireAtMillis'] == early.millisecondsSinceEpoch,
      );
      expect(lastArguments()['exact'], isTrue);

      await controller().togglePause(first.id);
      await waitFor(
        () => lastArguments()['fireAtMillis'] == late.millisecondsSinceEpoch,
      );
      expect(lastArguments()['exact'], isFalse);
      await controller().togglePause(first.id);
      await waitFor(
        () => lastArguments()['fireAtMillis'] == early.millisecondsSinceEpoch,
      );

      final edited = late.add(const Duration(hours: 1));
      final stored = await AutoReplyTriggerStorage().loadTriggers();
      await AutoReplyTriggerStorage().saveTriggers(
        stored.map((trigger) => trigger.copyWith(nextFireAt: edited)).toList(),
      );
      await controller().reloadFromStorage();
      await waitFor(
        () => lastArguments()['fireAtMillis'] == edited.millisecondsSinceEpoch,
      );
      expect(lastArguments()['exact'], isTrue);

      for (final trigger in stored) {
        await controller().deleteTrigger(trigger.id);
      }
      await waitFor(() => alarms.last.method == 'cancelProactiveAlarm');
      expect(lastArguments()['slot'], 'trigger');
    },
  );

  test(
    'disposing the controller preserves its synchronized future alarm',
    () async {
      final at = DateTime.now().add(const Duration(hours: 1));
      await create(at);
      await controller().flushAlarmSchedule();
      final count = alarms.length;
      fixture.container.invalidate(autoReplyTriggersProvider);
      await Future<void>.delayed(Duration.zero);
      expect(alarms, hasLength(count));
      expect(alarms.last.method, 'scheduleProactiveAlarm');
      expect(lastArguments()['fireAtMillis'], at.millisecondsSinceEpoch);
    },
  );

  test('foreign-owner triggers do not register a local alarm', () async {
    final at = DateTime.now().add(const Duration(hours: 1));
    await create(at);
    await waitFor(() => alarms.isNotEmpty);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      proactiveOwnerDevicesKey,
      jsonEncode({
        fixture.conversation.id: {'device_id': 'another-device', 'at_ms': 1},
      }),
    );
    await controller().reloadFromStorage();
    await waitFor(() => alarms.last.method == 'cancelProactiveAlarm');
  });

  test('a slow old schedule cannot overtake a later cancel', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    beforeAlarm = (call) async {
      if (call.method == 'scheduleProactiveAlarm' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final trigger = await create(DateTime.now().add(const Duration(hours: 1)));
    await entered.future;
    await controller().deleteTrigger(trigger.id);
    release.complete();
    await waitFor(
      () => alarms.isNotEmpty && alarms.last.method == 'cancelProactiveAlarm',
    );
    expect(alarms.first.method, 'scheduleProactiveAlarm');
    expect(alarms.last.method, 'cancelProactiveAlarm');
  });

  test(
    'native callback reloads storage and awaits every due delivery',
    () async {
      fixture.container.read(autoReplyServiceProvider);
      final at = DateTime.now().add(const Duration(seconds: 1));
      final triggers = [
        for (var i = 0; i < 2; i++)
          AutoReplyTrigger(
            id: 'due-$i',
            title: '提醒 $i',
            type: AutoReplyTriggerType.fixed,
            status: AutoReplyTriggerStatus.pending,
            createdAt: DateTime.now(),
            nextFireAt: at,
            allowNight: true,
            requireExact: true,
            delayMinutes: 0,
            manual: true,
            conversationId: fixture.conversation.id,
          ),
      ];
      await AutoReplyTriggerStorage().saveTriggers(triggers);
      final events = <AutoReplyTriggerEvent>[];
      final subscription = fixture.container
          .read(autoReplyTriggerEventBusProvider)
          .stream
          .listen(events.add);
      var callbackCompleted = false;
      final completed = Completer<void>();
      // ignore: deprecated_member_use
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onProactiveAlarmFired', {'slot': 'trigger'}),
        ),
        (response) {
          try {
            const StandardMethodCodec().decodeEnvelope(response!);
            callbackCompleted = true;
            completed.complete();
          } catch (error, stack) {
            completed.completeError(error, stack);
          }
        },
      );
      await generationEntered.future.timeout(const Duration(seconds: 10));
      expect(callbackCompleted, isFalse);
      generationFinish.complete();
      await completed.future.timeout(const Duration(seconds: 10));
      expect(generations, 2);
      final feedback = fixture.container.read(autoReplyTriggerEventProvider);
      expect(feedback?.type, AutoReplyTriggerEventType.fired);
      expect(feedback?.triggerId, 'due-1');
      expect(
        events.where((event) => event.type == AutoReplyTriggerEventType.fired),
        isEmpty,
      );
      expect(
        (await AutoReplyTriggerStorage().loadTriggers()).every(
          (trigger) => trigger.status == AutoReplyTriggerStatus.fired,
        ),
        isTrue,
      );
      final messages = await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(fixture.conversation.id);
      expect(messages, hasLength(2));
      expect(alarms.last.method, 'cancelProactiveAlarm');
      await subscription.cancel();
    },
  );

  test(
    'native-only mode survives build and awaits slots without local polling',
    () async {
      final headless = ProviderContainer(
        parent: fixture.container,
        overrides: [
          autoReplyTriggersProvider.overrideWith(
            AutoReplyTriggerController.new,
          ),
        ],
      );
      addTearDown(headless.dispose);
      final headlessController = headless.read(
        autoReplyTriggersProvider.notifier,
      )..useNativeAlarmsOnly();
      await headless.read(autoReplyTriggersProvider.future);
      final events = <AutoReplyTriggerEvent>[];
      final subscription = fixture.container
          .read(autoReplyTriggerEventBusProvider)
          .stream
          .listen(events.add);
      final trigger = await headlessController.createTrigger(
        title: 'headless',
        type: AutoReplyTriggerType.fixed,
        nextFireAt: DateTime.now().add(const Duration(milliseconds: 100)),
        allowNight: true,
        requireExact: false,
        delayMinutes: 0,
        conversationId: fixture.conversation.id,
      );
      await headlessController.flushAlarmSchedule();
      pendingSlots = [
        ['trigger'],
        [],
      ];
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(pendingSlots, [
        ['trigger'],
        [],
      ]);
      expect(generations, 0);
      expect(
        events.where((event) => event.type == AutoReplyTriggerEventType.fired),
        isEmpty,
      );
      expect(headlessController.findTriggerById(trigger.id)!.isActive, isTrue);
      expect(alarms.last.method, 'scheduleProactiveAlarm');

      var finished = false;
      final run = drainProactiveAlarmSlots(
        trigger: headlessController.pollDueTriggersForAlarm,
        analyzer: () async => fail('No analyzer slot was queued'),
      ).then((_) => finished = true);
      await generationEntered.future.timeout(const Duration(seconds: 10));
      // While generation holds the headless consumer, another local tick must
      // neither consume nor emit the still-active trigger.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(finished, isFalse);
      expect(generations, 1);
      expect(
        events.where((event) => event.type == AutoReplyTriggerEventType.fired),
        isEmpty,
      );
      generationFinish.complete();
      await run.timeout(const Duration(seconds: 10));
      expect(pendingSlots, isEmpty);
      expect(
        headlessController.findTriggerById(trigger.id)!.status,
        AutoReplyTriggerStatus.fired,
      );
      await subscription.cancel();
    },
  );

  test(
    'headless slot drain awaits trigger before analyzer and consumes late slots',
    () async {
      pendingSlots = [
        ['analyzer', 'trigger'],
        ['trigger'],
        [],
      ];
      final entered = Completer<void>();
      final release = Completer<void>();
      final order = <String>[];
      final run = drainProactiveAlarmSlots(
        trigger: () async {
          order.add('trigger');
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
        analyzer: () async {
          order.add('analyzer');
        },
      );
      await entered.future;
      expect(order, ['trigger']);
      release.complete();
      await run;
      expect(order, ['trigger', 'analyzer', 'trigger']);
      expect(pendingSlots, isEmpty);
    },
  );
}
