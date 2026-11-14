import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/services/android_keep_alive_manager.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_dispatch_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final oldPaths = PathProviderPlatform.instance;
  late Directory directory;
  late SegmentedChatFixture fixture;
  late Completer<void> entered;
  late Completer<void> finish;
  late List<bool> transitions;
  late bool active;
  late bool failGeneration;
  late bool failStart;
  late bool failRelease;
  late int generationCalls;

  setUpAll(() async {
    directory = await (await Directory(
      'build/batch1_dispatch_keep_alive',
    ).create(recursive: true)).createTemp();
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    entered = Completer<void>();
    finish = Completer<void>();
    transitions = [];
    active = false;
    failGeneration = false;
    failStart = false;
    failRelease = false;
    generationCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setGenerationActive') {
        active = (call.arguments as Map)['active'] == true;
        transitions.add(active);
        if (!active && failRelease) {
          throw PlatformException(code: 'stop_failed', message: 'stop denied');
        }
        return null;
      }
      return <String, Object>{
        'generationActive': active,
        'serviceRunning': active && !failStart,
        'generationWakeLockHeld': active && !failStart,
        'lastStartError': failStart ? 'start denied' : '',
      };
    });
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        proactiveReplyGeneratorProvider.overrideWith(
          (ref) => _Generator(ref, () async {
            generationCalls++;
            entered.complete();
            await finish.future;
            if (failGeneration) throw StateError('generation failed');
            return '主动问候';
          }),
        ),
      ],
    );
  });
  tearDown(() async {
    if (!finish.isCompleted) finish.complete();
    await fixture.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  AutoReplyTrigger trigger({bool cached = false}) => AutoReplyTrigger(
    id: 'keep_alive_trigger',
    title: '主动问候',
    type: AutoReplyTriggerType.delay,
    status: AutoReplyTriggerStatus.pending,
    createdAt: DateTime.now(),
    nextFireAt: DateTime.now(),
    allowNight: true,
    requireExact: false,
    delayMinutes: 0,
    manual: true,
    conversationId: fixture.conversation.id,
    cachedContent: cached ? '缓存问候' : null,
    preparedAt: cached ? DateTime.now() : null,
  );

  Future<AutoReplyDispatchResult> dispatch({bool cached = false}) => fixture
      .container
      .read(autoReplyDispatchServiceProvider)
      .dispatchTestTrigger(trigger(cached: cached));

  for (final fail in [false, true]) {
    test('live generation holds and releases lease (failure: $fail)', () async {
      failGeneration = fail;
      final sending = dispatch();
      await entered.future.timeout(const Duration(seconds: 10));
      final heldDuringGeneration = active;
      final transitionsDuringGeneration = List<bool>.of(transitions);
      finish.complete();
      final result = await sending;
      expect(heldDuringGeneration, isTrue);
      expect(transitionsDuringGeneration, [true]);
      expect(transitions, [true, false]);
      expect(active, isFalse);
      expect(result.success, !fail);
      if (fail) expect(result.reason, contains('generation failed'));
    });
  }

  test('native start failure warns but generation still succeeds', () async {
    failStart = true;
    final logStart = AppLogger.entries.value.length;
    final sending = dispatch();
    await entered.future.timeout(const Duration(seconds: 10));
    finish.complete();
    final result = await sending;
    expect(result.success, isTrue);
    expect(generationCalls, 1);
    expect(transitions, [true, false]);
    expect(
      AppLogger.entries.value.skip(logStart),
      contains(
        isA<LogEntry>()
            .having((entry) => entry.level, 'level', LogLevel.warning)
            .having(
              (entry) => entry.source,
              'source',
              'AutoReplyDispatchService',
            )
            .having(
              (entry) => entry.metadata?['error'],
              'error',
              contains('start denied'),
            ),
      ),
    );
  });

  test('fresh cached delivery does not acquire a generation lease', () async {
    expect((await dispatch(cached: true)).success, isTrue);
    expect(generationCalls, 0);
    expect(transitions, isEmpty);
  });

  for (final fail in [false, true]) {
    test('release failure preserves generation result (failure: $fail)', () async {
      failRelease = true;
      failGeneration = fail;
      final logStart = AppLogger.entries.value.length;
      final sending = dispatch();
      await entered.future.timeout(const Duration(seconds: 10));
      finish.complete();
      final result = await sending;
      expect(result.success, !fail);
      expect(transitions, [true, false]);
      final messages = await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(fixture.conversation.id);
      if (fail) {
        expect(result.reason, contains('generation failed'));
        expect(result.reason, isNot(contains('stop denied')));
        expect(messages, isEmpty);
      } else {
        expect(messages, hasLength(1));
        expect(messages.single.content, '主动问候');
      }
      expect(
        AppLogger.entries.value.skip(logStart),
        contains(
          isA<LogEntry>()
              .having((entry) => entry.level, 'level', LogLevel.warning)
              .having(
                (entry) => entry.source,
                'source',
                'AutoReplyDispatchService',
              )
              .having(
                (entry) => entry.metadata?['error'],
                'error',
                contains('stop denied'),
              ),
        ),
      );
    });
  }

  test(
    'dispatch releases only its lease while another generation is active',
    () async {
      final otherLease = await AndroidKeepAliveManager.acquireGenerationLease();
      try {
        final sending = dispatch();
        await entered.future.timeout(const Duration(seconds: 10));
        finish.complete();
        expect((await sending).success, isTrue);
        expect(active, isTrue);
        expect(transitions, [true, true]);
      } finally {
        await otherLease!.release();
      }
      expect(transitions, [true, true, false]);
    },
  );
}
