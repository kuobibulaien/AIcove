import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_deferred_image_delivery.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_tts_handler.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/chat/services/tts_fallback_notification.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';

final _refProvider = Provider<Ref>((ref) => ref);

class _Settings extends AppSettingsNotifier {
  _Settings(this.settings);
  final AppSettings settings;
  @override
  Future<AppSettings> build() async => settings;
}

class _Generator implements ChatMediaGenerationPort {
  var calls = 0;
  String? customPrompt;
  @override
  Future<GeneratedChatMedia> generate(
    String conversationId,
    String input, {
    ImageGenerationSnapshot? imageSnapshot,
    String? customPrompt,
  }) async {
    calls++;
    this.customPrompt = customPrompt;
    return const GeneratedChatMedia.image('/redrawn.png');
  }
}

class _Timeline extends ConversationTimelineCache {
  _Timeline(super.ref);
  final messages = <Message>[];
  @override
  Future<void> replaceMessagesTransient({
    required String conversationId,
    List<String> removeMessageIds = const [],
    List<Message> messages = const [],
  }) async {
    this.messages.removeWhere(
      (message) => removeMessageIds.contains(message.id),
    );
    this.messages.addAll(messages);
  }

  @override
  Future<List<Message>> loadCachedMessages(String conversationId) async =>
      List.of(messages);
}

class _Store extends ChatHistoryStore {
  _Store(super.ref, this.timeline);
  final _Timeline timeline;
  final updates = <Message>[];
  MediaRegenerationTarget? regenerationTarget;
  @override
  Future<MediaRegenerationTarget> loadMediaRegenerationTarget({
    required String conversationId,
    required String messageId,
    required String blockId,
  }) async => regenerationTarget!;

  @override
  Future<void> replaceGeneratedMedia({
    required String conversationId,
    required MediaRegenerationTarget target,
    required GeneratedChatMedia result,
  }) async {}

  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
    bool updateSummary = true,
    FutureOr<bool> Function()? shouldCommit,
  }) async {}

  @override
  Future<void> appendMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
    FutureOr<bool> Function()? shouldCommit,
  }) async => timeline.messages.add(message);

  @override
  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) async {}

  @override
  Future<void> insertMessagesAroundAnchor({
    required String conversationId,
    required List<String> anchorIds,
    required List<ConversationSupplementInsertOp> insertOps,
    FutureOr<bool> Function()? shouldCommit,
  }) async => timeline.messages.addAll(insertOps.map((op) => op.message));

  @override
  Future<Message?> loadFrontendMessageById(
    String id, {
    String? conversationId,
  }) async =>
      timeline.messages.where((message) => message.id == id).firstOrNull;
  @override
  Future<void> updateMessage({
    required String conversationId,
    required Message message,
    String? lastMessagePreview,
    FutureOr<bool> Function()? shouldCommit,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (shouldCommit != null && !await shouldCommit()) return;
    updates.add(message);
    final index = timeline.messages.indexWhere((item) => item.id == message.id);
    timeline.messages[index] = message;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Timeline timeline;
  late _Store store;
  late ChatDeferredImageDelivery delivery;
  late List<Future<void> Function()> tasks;
  late List<TtsFallbackEvent> events;
  var commit = true;
  Completer<void>? mutationGate;
  late AppSettings currentSettings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    currentSettings = mapUiModelsToAppSettings(
      {},
    ).copyWith(streamSegmentDelaySeconds: 0);
    tasks = [];
    events = [];
    commit = true;
    mutationGate = null;
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(() => _Settings(currentSettings)),
        ttsPlayerManagerProvider.overrideWithValue(null),
        pluginManagerProvider.overrideWithValue(PluginManager()),
        conversationTimelineCacheProvider.overrideWith(
          (ref) => timeline = _Timeline(ref),
        ),
        chatHistoryStoreProvider.overrideWith(
          (ref) => store = _Store(
            ref,
            ref.read(conversationTimelineCacheProvider) as _Timeline,
          ),
        ),
      ],
    );
    container.read(conversationTimelineCacheProvider);
    container.read(chatHistoryStoreProvider);
    final subscription = container
        .read(ttsFallbackNotificationServiceProvider)
        .stream
        .listen(events.add);
    addTearDown(subscription.cancel);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    var tail = Future<void>.value();
    delivery = ChatDeferredImageDelivery(
      ref: container.read(_refProvider),
      enqueueStoreMutation: (task) => tail = tail.then((_) async {
        await mutationGate?.future;
        await task();
      }),
      runBackgroundTask: (_, task) => tasks.add(task),
    );
  });

  Message text(
    String id, {
    String role = 'assistant',
    String? source = 'user',
  }) => Message(
    id: id,
    role: role,
    sourceMessageId: source,
    content: 'text-$id',
    createdAt: DateTime(2026),
  );

  Future<void> runJobs({
    String? anchor,
    int count = 1,
    String? source = 'user',
    bool hasPlaceholder = false,
  }) async {
    delivery.scheduleJobs(
      convId: 'conversation',
      shouldCommit: () => commit,
      jobs: [
        for (var i = 0; i < count; i++)
          DeferredImageJob(
            messageId: 'image-$i',
            prompt: 'prompt-$i',
            createdAt: DateTime(2026),
            failureAnchorMessageId: anchor,
            sourceMessageId: source,
            hasPlaceholder: hasPlaceholder,
          ),
      ],
    );
    final pending = List.of(tasks);
    tasks.clear();
    await Future.wait(pending.map((task) => task()));
    await Future<void>.delayed(Duration.zero);
  }

  void registerImagePlugin() {
    final settings = mapUiModelsToAppSettings({}).copyWith(
      imageGenerationEnabled: true,
      modelTypes: {'local:image': 'image'},
      modelProviderMap: {'local:image': 'local'},
      providers: [
        const ProviderAuth(
          id: 'local',
          apiKeys: ['key'],
          apiBaseUrl: 'https://local.test/v1',
          models: ['image'],
          visibleModels: ['image'],
          capabilities: ['image'],
        ),
      ],
    );
    currentSettings = settings.copyWith(streamSegmentDelaySeconds: 0);
    container.invalidate(appSettingsProvider);
    container
        .read(pluginManagerProvider)
        .register(
          ImagePlugin(
            const ImageConfig(
              selectedProviderId: 'local',
              selectedModelId: 'local:image',
            ),
            container.read(_refProvider),
            requestSettings: settings,
          ),
        );
  }

  test('background snapshot generates direct image prompts in order', () async {
    registerImagePlugin();
    await container.read(appSettingsProvider.future);
    final output = await Directory.systemTemp.createTemp(
      'aicove-direct-images-',
    );
    addTearDown(() => output.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => output.path);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final requests = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'data': [
            {
              'b64_json': base64Encode([1, 2, 3]),
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    const display =
        '正文<image>{"id":1,"prompt":"first scene","width":512}</image>'
        '<image>{"id":2,"prompt":"second scene","height":768}</image>';
    final raw = Message(
      id: 'raw',
      role: 'assistant',
      content: display,
      createdAt: DateTime(2026),
    );
    final messages = await http.runWithClient(
      () => container
          .read(chatTtsHandlerProvider)
          .prepareBackgroundSnapshot(
            convId: 'conversation',
            rawMessage: raw,
            buildResult: AssistantMessageBuildResult(
              rawMessage: raw,
              messages: [],
              lastMessageText: '',
            ),
            replyText: display,
            pluginEvents: [
              for (var i = 0; i < 2; i++)
                PluginEvent(
                  pluginId: 'image',
                  type: 'image_generate',
                  data: {
                    'drawingConfig': const ImageConfig(
                      selectedProviderId: 'local',
                      selectedModelId: 'local:image',
                    ).toJson(),
                  },
                ),
            ],
            ttsEnabled: false,
          ),
      () => client,
    );
    expect(requests.map((request) => request['prompt']), [
      'first scene',
      'second scene',
    ]);
    const defaults = ImageConfig();
    expect(requests.map((request) => request['size']), [
      '512x${defaults.defaultHeight}',
      '${defaults.defaultWidth}x768',
    ]);
    final images = messages.expand((message) => message.images).toList();
    expect(images.map((image) => image.generationSnapshot!.basePrompt), [
      'first scene',
      'second scene',
    ]);
    expect(
      images.every((image) => image.status == BlockStatus.success),
      isTrue,
    );
    for (final image in images) {
      expect(await File(image.localPath!).exists(), isTrue);
    }
  });

  test(
    'direct prompt snapshot failure retains the existing text fallback',
    () async {
      final raw = Message(
        id: 'raw',
        role: 'assistant',
        content: '<image>direct scene</image>',
        createdAt: DateTime(2026),
      );
      final messages = await container
          .read(chatTtsHandlerProvider)
          .prepareBackgroundSnapshot(
            convId: 'conversation',
            rawMessage: raw,
            buildResult: AssistantMessageBuildResult(
              rawMessage: raw,
              messages: [],
              lastMessageText: '',
            ),
            replyText: raw.content,
            pluginEvents: [
              PluginEvent(pluginId: 'image', type: 'image_generate', data: {}),
            ],
            ttsEnabled: false,
            fallbackFailedMedia: true,
          );
      expect(messages.single.displayText, '[图片：direct scene]');
    },
  );

  for (final basePrompt in ['']) {
    for (final customPrompt in <String?>[null, 'draw a beach']) {
      test(
        'redraw guard handles unresolved prompt "$basePrompt", custom=$customPrompt',
        () async {
          final block = ImageBlock(
            id: 'image',
            messageId: 'm',
            status: BlockStatus.error,
            prompt: basePrompt,
            generationSnapshot: ImageGenerationSnapshot(
              providerId: 'local',
              modelId: 'image',
              requestProvider: 'openai',
              prompt: basePrompt,
              basePrompt: basePrompt,
              negativePrompt: null,
              width: 512,
              height: 768,
              steps: 20,
              guidanceScale: 7,
            ),
          );
          store.regenerationTarget = MediaRegenerationTarget(
            message: Message.fromBlocks(
              id: 'm',
              role: 'assistant',
              blocks: [block],
              createdAt: DateTime(2026),
            ),
            block: block,
            rawRevision: 'revision',
          );
          final generator = _Generator();
          final action = ChatMediaRegeneration(
            store: store,
            generators: {RegeneratableMediaKind.image: generator},
            isSending: (_) => false,
          );
          final result = action.regenerate(
            conversationId: 'conversation',
            messageId: 'm',
            blockId: 'image',
            customPrompt: customPrompt,
          );
          if (customPrompt == null) {
            await expectLater(
              result,
              throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'message',
                  '该图片尚未生成分镜提示词，请长按选择「改词重画」输入画面描述',
                ),
              ),
            );
            expect(generator.calls, 0);
          } else {
            await result;
            expect(generator.calls, 1);
            expect(generator.customPrompt, customPrompt);
          }
        },
      );
    }
  }

  for (final invalidated in [false, true]) {
    test(
      'failed pending image is removed even when invalidated=$invalidated',
      () async {
        timeline.messages.add(
          delivery.buildPendingPlaceholderMessage(
            messageId: 'image-0',
            prompt: 'prompt-0',
            createdAt: DateTime(2026),
          ),
        );
        expect(timeline.messages.single.status, 'sent');
        expect(
          timeline.messages.single.blocks!.single.status,
          BlockStatus.pending,
        );
        commit = !invalidated;
        await runJobs();
        expect(timeline.messages, isEmpty);
        expect(events, hasLength(invalidated ? 0 : 1));
        expect(store.updates, isEmpty);
      },
    );
  }

  test(
    'failed placeholder keeps its identity, position, prompt and dimensions',
    () async {
      final placeholder = delivery.buildPendingPlaceholderMessage(
        messageId: 'image-0',
        prompt: 'prompt-0',
        createdAt: DateTime(2026),
        sourceMessageId: 'user',
        width: 512,
        height: 768,
      );
      timeline.messages.addAll([text('first'), placeholder, text('last')]);
      await runJobs(hasPlaceholder: true);
      expect(timeline.messages.map((message) => message.id), [
        'first',
        'image-0',
        'last',
      ]);
      final failed = timeline.messages[1];
      final image = failed.blocks!.whereType<ImageBlock>().single;
      expect(failed.createdAt, placeholder.createdAt);
      expect(failed.sourceMessageId, 'user');
      expect(image.id, placeholder.blocks!.single.id);
      expect(image.status, BlockStatus.error);
      expect(image.prompt, 'prompt-0');
      expect((image.width, image.height), (512, 768));
    },
  );

  test(
    'invalidated retained placeholder is removed without a failure update',
    () async {
      timeline.messages.add(
        delivery.buildPendingPlaceholderMessage(
          messageId: 'image-0',
          prompt: 'prompt-0',
          createdAt: DateTime(2026),
        ),
      );
      commit = false;
      await runJobs(hasPlaceholder: true);
      expect(timeline.messages, isEmpty);
      expect(store.updates, isEmpty);
      expect(events, isEmpty);
    },
  );

  test('deleted failed page is never recreated', () async {
    await runJobs(hasPlaceholder: true);
    expect(timeline.messages, isEmpty);
    expect(store.updates, isEmpty);
  });

  for (final anchor in <String?>[null, 'missing', 'previous']) {
    test('failure does not attach to another round, anchor=$anchor', () async {
      timeline.messages.addAll([
        text('previous', source: 'previous-raw'),
        text('current-user', role: 'user'),
      ]);
      await runJobs(anchor: anchor);
      expect(store.updates, isEmpty);
      expect(events, hasLength(1));
    });
  }

  test('unidentified round has no implicit fallback anchor', () async {
    timeline.messages.add(text('previous', source: null));
    await runJobs(source: null);
    expect(store.updates, isEmpty);
  });

  test('image-only failure still notifies without an anchor', () async {
    await runJobs(count: 2);
    expect(events.map((event) => event.message), ['图片生成失败，可稍后重试或检查绘图渠道']);
    expect(store.updates, isEmpty);
  });

  for (final anchor in <String?>[null, 'missing', 'first']) {
    test(
      'failures preserve every hidden context with anchor=$anchor',
      () async {
        timeline.messages.addAll([
          text('first'),
          text('last'),
          text('user', role: 'user'),
          Message.fromBlocks(
            id: 'image-only',
            role: 'assistant',
            createdAt: DateTime(2026),
            blocks: [
              ImageBlock(messageId: 'image-only', localPath: '/fixture.png'),
            ],
          ),
        ]);
        await runJobs(anchor: anchor, count: 3, source: 'user');
        final target = anchor == 'first' ? 'first' : 'last';
        expect(store.updates.map((message) => message.id), [
          target,
          target,
          target,
        ]);
        final message = timeline.messages.firstWhere(
          (message) => message.id == target,
        );
        expect(
          message.blocks!.whereType<ToolBlock>().map(
            (block) => block.result!['raw_prompt'],
          ),
          ['prompt-0', 'prompt-1', 'prompt-2'],
        );
        expect(message.displayText, 'text-$target');
        expect(events, hasLength(1));
      },
    );
  }

  test(
    'fallback preserves assistant content when the block list is empty',
    () async {
      timeline.messages.add(text('anchor').copyWith(blocks: <MessageBlock>[]));
      await runJobs();
      expect(store.updates.single.displayText, 'text-anchor');
      expect(store.updates.single.blocks!.whereType<ToolBlock>(), hasLength(1));
    },
  );

  test('source user message is not used as a failure anchor', () async {
    timeline.messages.add(text('user', role: 'user'));
    await runJobs(source: 'user');
    expect(store.updates, isEmpty);
    expect(events, hasLength(1));
  });

  test(
    'anchor is resolved from the latest timeline inside the mutation queue',
    () async {
      timeline.messages.add(text('old'));
      mutationGate = Completer<void>();
      final pending = runJobs(anchor: 'old');
      await Future<void>.delayed(Duration.zero);
      timeline.messages
        ..clear()
        ..add(text('new'));
      mutationGate!.complete();
      await pending;
      expect(store.updates.single.id, 'new');
    },
  );

  test('superseded queued failures do not mutate the timeline', () async {
    timeline.messages.add(text('anchor'));
    mutationGate = Completer<void>();
    final pending = runJobs(anchor: 'anchor');
    await Future<void>.delayed(Duration.zero);
    commit = false;
    mutationGate!.complete();
    await pending;
    expect(store.updates, isEmpty);
  });

  test('new scheduleJobs call is a new notification round', () async {
    await runJobs();
    await runJobs();
    expect(events, hasLength(2));
  });

  test('superseded failures neither notify nor mutate', () async {
    timeline.messages.add(text('anchor'));
    commit = false;
    await runJobs(anchor: 'anchor', count: 2);
    expect(events, isEmpty);
    expect(store.updates, isEmpty);
  });
}
