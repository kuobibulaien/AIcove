import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
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

class _Send extends ChatSendService {
  _Send(super.ref);
  int requests = 0;
  Completer<void>? persistBarrier;
  final persisting = Completer<void>();

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    persisting.complete();
    await persistBarrier?.future;
    await super.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
    DateTime? requestTime,
    bool persistSideEffects = true,
    bool deferReminders = false,
    bool forceInlineImageRoute = false,
  }) async => const ApiConfig(
    settings: segmentedProbeSettings,
    modelFullId: 'offline:probe',
    providerApiBase: '',
    providerApiKey: null,
    customConfig: {},
    messages: [],
  );

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) async {
    requests++;
    return const ApiCallResult(
      processedText: '收到。',
      replyText: '收到。',
      pluginEvents: [],
      toolResults: [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.example.aicove_flutter/keep_alive');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final oldPaths = PathProviderPlatform.instance;
  late Directory directory;
  late SegmentedChatFixture fixture;
  late _Send service;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('keep_alive_order_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        chatSendServiceProvider.overrideWith((ref) => service = _Send(ref)),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() async {
    await fixture.dispose();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final kind in ['text', 'image', 'file', 'cancel']) {
    test(
      '$kind publishes user before keep-alive, but waits before model',
      () async {
        final ready = Completer<void>();
        final polled = Completer<void>();
        final active = <bool>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setGenerationActive') {
            active.add((call.arguments as Map)['active'] as bool);
          } else if (call.method == 'getStatus') {
            if (!polled.isCompleted) polled.complete();
            await ready.future;
            return {
              'generationActive': true,
              'serviceRunning': true,
              'generationWakeLockHeld': true,
            };
          }
          return null;
        });
        final actions = fixture.container.read(chatActionsProvider);
        final file = await File(
          '${directory.path}/attachment.txt',
        ).writeAsString('test');
        final send = switch (kind) {
          'image' => actions.sendWithImage('${directory.path}/image.png'),
          'file' => actions.sendWithFile(file.path),
          _ => actions.send('用户消息'),
        };
        Future<void>? interrupt;
        try {
          if (kind != 'file') {
            expect(
              fixture.container.read(
                conversationSendingProvider(fixture.conversation.id),
              ),
              isTrue,
            );
          }
          await polled.future.timeout(const Duration(seconds: 5));
          await fixture.waitUntil(
            () => fixture.timeline.value.any((m) => m.role == 'user'),
          );
          final raw = await fixture.container
              .read(chatHistoryStoreProvider)
              .loadAllRawMessages(fixture.conversation.id);
          expect(raw.where((m) => m.role == 'user'), hasLength(1));
          expect(service.requests, 0);
          if (kind == 'cancel') {
            interrupt = actions.interruptCurrentGeneration(
              convId: fixture.conversation.id,
            );
          }
        } finally {
          ready.complete();
          await interrupt;
          await send;
        }
        expect(service.requests, kind == 'cancel' ? 0 : 1);
        expect(active, [true, false]);
        expect(
          fixture.container.read(
            conversationSendingProvider(fixture.conversation.id),
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'keep-alive failure during persistence is observed and falls back',
    () async {
      final failed = Completer<void>();
      final releasePersistence = Completer<void>();
      service.persistBarrier = releasePersistence;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'setGenerationActive' &&
            (call.arguments as Map)['active'] == true) {
          await service.persisting.future;
          failed.complete();
          throw PlatformException(code: 'guard_failed');
        }
        return null;
      });
      final send = fixture.container.read(chatActionsProvider).send('保留用户消息');
      try {
        await failed.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(service.requests, 0);
      } finally {
        releasePersistence.complete();
        await send;
      }
      expect(service.requests, 1);
      expect(
        fixture.timeline.value.where((m) => m.role == 'user'),
        hasLength(1),
      );
    },
  );
}
