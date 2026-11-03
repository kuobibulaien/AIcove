import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_request_config.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_agent_definition.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_config.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/provider_key_failure.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/context/data/background_context_summarizer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/workspace/webapp/webapp_ai.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../../../tool/chat_segmented_fixture.dart';

ProviderAuth _provider(
  String id, {
  String strategy = 'round_robin',
  List<Map<String, Object?>>? items,
}) => ProviderAuth(
  id: id,
  apiKeys: const ['legacy'],
  apiBaseUrl: 'https://model.invalid/v1',
  models: const ['chat'],
  customConfig: {
    'requestFormat': 'openai',
    'multi_key_enabled': true,
    'multi_key_strategy': strategy,
    'multi_key_items':
        items ??
        const [
          {'id': 'one', 'key': 'key-one', 'enabled': true, 'status': 'normal'},
          {'id': 'two', 'key': 'key-two', 'enabled': true, 'status': 'normal'},
        ],
  },
);
AppSettings _settings(ProviderAuth p) => mapUiModelsToAppSettings({}).copyWith(
  providers: [p],
  defaultModelName: '${p.id}:chat',
  defaultChatModels: ['${p.id}:chat'],
  modelProviderMap: {'${p.id}:chat': p.id, 'chat': p.id},
);
const _reply = ApiCallResult(
  replyText: 'ok',
  processedText: 'ok',
  pluginEvents: [],
  toolResults: [],
);

class _Runner implements ApiRunner {
  _Runner(this.send);
  final Future<ApiCallResult> Function(ApiConfig) send;
  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required responseProcessors,
    availableTools,
    String? turnId,
    trace,
    void Function(String)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
    traceContext,
    cancellation,
  }) => send(config);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _BrokenSettings extends AppSettingsNotifier {
  @override
  Future<void> recordProviderMultiKeyFailure({
    required String providerId,
    required String failedKey,
    required String? strategy,
    String? failedItemId,
    int? failedItemIndex,
    required Object error,
  }) async => throw StateError('storage unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var serial = 0;
  late Directory directory;
  late TraceStore traces;
  final oldPaths = PathProviderPlatform.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'direct.enable': false});
    directory = await Directory.systemTemp.createTemp('multi_key_pipeline_');
    PathProviderPlatform.instance = _Paths(directory.path);
    traces = TraceStore(rootDirResolver: () async => directory);
  });
  tearDown(() async {
    await traces.waitForPendingWrites();
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });

  test(
    'read-only probes share the next round-robin key without consuming it',
    () async {
      final settings = _settings(_provider('preview-${serial++}'));
      final builder = ChatRequestConfigBuilder();
      for (var i = 0; i < 3; i++) {
        expect(
          (await builder.buildRequestConfig(
            settings,
            consumeKeyRotation: false,
          )).providerApiKey,
          'key-one',
        );
        expect(
          (await resolveAutoReplyRequestConfig(settings)).providerApiKey,
          'key-one',
        );
      }
      expect(
        (await builder.buildRequestConfig(settings)).providerApiKey,
        'key-one',
      );
      expect(
        (await builder.buildRequestConfig(
          settings,
          consumeKeyRotation: false,
        )).providerApiKey,
        'key-two',
      );
      expect(
        (await builder.buildRequestConfig(settings)).providerApiKey,
        'key-two',
      );
    },
  );

  test(
    'background, task and webapp consume one shared sequence with full identity',
    () async {
      final settings = _settings(_provider('flows-${serial++}'));
      final seen = <ApiConfig>[];
      Future<ApiCallResult> execute(ApiConfig config) async {
        seen.add(config);
        return _reply;
      }

      await BackgroundAgentService(
        loadRecentMessages: (_, _) async => [],
        loadSettings: () async => settings,
        traceStore: traces,
        executor:
            ({required config, required availableTools, required sessionId}) =>
                execute(config),
      ).run(
        definition: const BackgroundAgentDefinition(
          id: 'probe',
          name: 'probe',
          objectivePrompt: 'probe',
        ),
        conversationId: 'c',
        contextMessages: [],
      );
      await TaskAgentRunner(
        loadSettings: () async => settings,
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) => execute(config),
      ).run(
        taskId: 'task',
        runId: 'run',
        transcript: 'probe',
        capabilities: const TaskAgentCapabilities(),
        preset: const TaskAgentPreset(),
        cancellation: KernelCancellation(),
      );
      await createWebAppAiChat(
        loadSettings: () async => settings,
        executor: ({required config}) => execute(config),
      )(
        const WebAppAiRequest(
          messages: [
            {'role': 'user', 'content': 'probe'},
          ],
        ),
      );
      expect(seen.map((c) => c.providerApiKey), [
        'key-one',
        'key-two',
        'key-one',
      ]);
      expect(seen.map((c) => c.providerApiKeyItemId), ['one', 'two', 'one']);
      expect(seen.map((c) => c.providerApiKeyItemIndex), [0, 1, 0]);
      expect(
        seen.map((c) => c.providerId),
        everyElement(settings.providers.single.id),
      );
      expect(
        seen.map((c) => c.providerApiKeyStrategy),
        everyElement('round_robin'),
      );
    },
  );

  test('real context previews leave the next request key untouched', () async {
    final settings = _settings(_provider('context-preview-${serial++}'));
    final fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      settings: settings,
      enabledPlugins: [],
    );
    addTearDown(fixture.dispose);
    final sender = fixture.container.read(chatSendServiceProvider);
    await sender.previewContext(fixture.conversation);
    await sender.previewContext(fixture.conversation);
    expect(
      (await ChatRequestConfigBuilder().buildRequestConfig(
        settings,
      )).providerApiKey,
      'key-one',
    );
  });

  test(
    'enabled/healthy items and legacy/direct fallback keep the chat rules',
    () async {
      final builder = ChatRequestConfigBuilder();
      final p = _provider(
        'eligibility',
        items: const [
          {'id': 'off', 'key': 'off', 'enabled': false},
          {'id': 'bad', 'key': 'bad', 'status': 'error'},
          {'id': 'good', 'key': 'good', 'enabled': true},
        ],
      );
      expect(
        (await builder.buildRequestConfig(_settings(p))).providerApiKey,
        'good',
      );
      expect(
        (await resolveAutoReplyRequestConfig(_settings(p))).providerApiKey,
        'good',
      );
      final legacy = p.copyWith(
        apiKeys: ['first', 'second'],
        customConfig: {'multi_key_enabled': true},
      );
      expect(
        (await builder.buildRequestConfig(_settings(legacy))).providerApiKey,
        'first',
      );
      final none = p.copyWith(apiKeys: [], customConfig: {});
      expect(
        (await builder.buildRequestConfig(_settings(none))).providerApiKey,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('direct.enable', true);
      await prefs.setString('direct.api_key', 'direct-key');
      final fallback = await BackgroundAgentService.resolveRequestConfig(
        settings: _settings(none),
        modelRef: null,
      );
      expect(fallback.providerApiKey, 'direct-key');
      expect(fallback.providerApiKeyItemId, isNull);
    },
  );

  Future<(AppSettingsNotifier, ProviderKeyFailureRecorder)> recorder({
    String id = 'channel',
  }) async {
    final p = _provider(id, strategy: 'exhaust');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      cloudUiModelsKey,
      jsonEncode({
        'providers': [p.toJson()],
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    return (notifier, ProviderKeyFailureRecorder(() => notifier));
  }

  Future<ApiConfig> configFor(
    AppSettingsNotifier notifier, {
    KernelCancellation? cancellation,
  }) async {
    final settings = await notifier.readStored();
    final request = await ChatRequestConfigBuilder().buildRequestConfig(
      settings,
      modelRef: 'channel:chat',
    );
    return ApiConfig(
      settings: settings,
      modelFullId: request.modelFullId,
      providerApiBase: request.providerApiBase,
      providerApiKey: request.providerApiKey,
      providerId: request.providerId,
      providerApiKeyItemId: request.providerApiKeyItemId,
      providerApiKeyItemIndex: request.providerApiKeyItemIndex,
      providerApiKeyStrategy: request.providerApiKeyStrategy,
      customConfig: request.customConfig,
      messages: const [],
      cancellation: cancellation,
    );
  }

  Future<void> fail(
    ProviderKeyFailureRecorder book,
    ApiConfig config,
    Object error,
  ) => expectLater(
    executeWithProviderKeyFailureRecording(
      config: config,
      recorder: book,
      execute: () async => throw modelRequestFailure(error),
    ),
    throwsA(same(error)),
  );

  Future<List<ProviderMultiKeyItem>> items(
    AppSettingsNotifier notifier,
  ) async => providerMultiKeyItemsFromProvider(
    (await notifier.readStored()).getProvider('channel')!,
  );

  for (final flow in ['chat', 'background', 'task', 'webapp']) {
    test(
      '$flow records model HTTP failures, never local errors or cancellation',
      () async {
        final (notifier, book) = await recorder();
        final settings = _settings(
          (await notifier.readStored()).getProvider('channel')!,
        );
        final signal = KernelCancellation();
        Object error = StateError('local');
        Future<ApiCallResult> execute(ApiConfig config) async {
          if (error is ModelHttpException) throw modelRequestFailure(error);
          throw error;
        }

        Future<void> run() async {
          switch (flow) {
            case 'chat':
              final container = ProviderContainer(
                overrides: [
                  providerKeyFailureRecorderProvider.overrideWithValue(book),
                ],
              );
              addTearDown(container.dispose);
              final backend = container.read(
                Provider(
                  (ref) => ChatSendBackendService(
                    ref,
                    readImageAsBase64: (_) async => null,
                    shouldUseNonVisionImageFlow:
                        ({required settings, required modelRef}) => false,
                    resolveTimeAwarenessPreviousUserMessageTime: (_) => null,
                    apiRunner: _Runner(execute),
                  ),
                ),
              );
              await backend.executeApiCall(
                config: await configFor(notifier, cancellation: signal),
                sessionId: 'c',
                userText: null,
              );
            case 'background':
              await BackgroundAgentService(
                loadRecentMessages: (_, _) async => [],
                loadSettings: () async => settings,
                keyFailureRecorder: book,
                traceStore: traces,
                executor:
                    ({
                      required config,
                      required availableTools,
                      required sessionId,
                    }) => execute(config),
              ).run(
                definition: const BackgroundAgentDefinition(
                  id: 'probe',
                  name: 'probe',
                  objectivePrompt: 'probe',
                ),
                conversationId: 'c',
                contextMessages: [],
              );
            case 'task':
              await TaskAgentRunner(
                loadSettings: () async => settings,
                keyFailureRecorder: book,
                executor:
                    ({
                      required config,
                      required tools,
                      required sessionId,
                      required cancellation,
                    }) => execute(config),
              ).run(
                taskId: 'task',
                runId: 'run',
                transcript: 'probe',
                capabilities: const TaskAgentCapabilities(),
                preset: const TaskAgentPreset(),
                cancellation: signal,
              );
            case 'webapp':
              await createWebAppAiChat(
                loadSettings: () async => settings,
                keyFailureRecorder: book,
                executor: ({required config}) => execute(config),
              )(
                const WebAppAiRequest(
                  messages: [
                    {'role': 'user', 'content': 'probe'},
                  ],
                ),
              );
          }
        }

        for (final local in [
          StateError('local'),
          TimeoutException('local tool'),
          const SocketException('local connector'),
          const FormatException('local parse'),
          const KernelCancelledException(),
        ]) {
          error = local;
          await expectLater(run(), throwsA(anything));
          expect((await items(notifier)).first.failedRequests, 0);
        }
        error = const ModelHttpException(401, 'invalid credential');
        await expectLater(run(), throwsA(anything));
        expect((await items(notifier)).first.failedRequests, 1);
        expect((await configFor(notifier)).providerApiKey, 'key-two');
      },
    );
  }

  test(
    'bookkeeping storage failure preserves the original model exception',
    () async {
      final (notifier, _) = await recorder();
      final config = await configFor(notifier);
      const error = ModelHttpException(401, 'original');
      await expectLater(
        executeWithProviderKeyFailureRecording(
          config: config,
          recorder: ProviderKeyFailureRecorder(() => _BrokenSettings()),
          execute: () async => throw modelRequestFailure(error),
        ),
        throwsA(same(error)),
      );
    },
  );

  test(
    'model network and explicit provider response failures are counted',
    () async {
      final (notifier, book) = await recorder();
      final config = await configFor(notifier);
      await fail(book, config, const SocketException('model socket'));
      await fail(book, config, Exception('SSE error: rejected'));
      expect((await items(notifier)).first.failedRequests, 2);
    },
  );

  test('cancelled token excludes even a late model HTTP error', () async {
    final (notifier, book) = await recorder();
    final signal = KernelCancellation()..cancel();
    await fail(
      book,
      await configFor(notifier, cancellation: signal),
      const ModelHttpException(401, 'late'),
    );
    expect((await items(notifier)).first.failedRequests, 0);
  });

  test(
    'failure bookkeeping reloads an externally changed credential before matching',
    () async {
      final (notifier, book) = await recorder();
      final request = await configFor(notifier);
      final prefs = await SharedPreferences.getInstance();
      final raw =
          jsonDecode(prefs.getString(cloudUiModelsKey)!)
              as Map<String, dynamic>;
      final providers = raw['providers'] as List;
      final provider = providers.cast<Map<String, dynamic>>().singleWhere(
        (p) => p['id'] == 'channel',
      );
      final custom = provider['custom_config'] as Map<String, dynamic>;
      final entries = custom['multi_key_items'] as List;
      (entries.first as Map<String, dynamic>)['key'] = 'externally-replaced';
      // Simulate another isolate changing native storage while this prefs
      // instance still holds the old request's credential in its cache.
      await SharedPreferencesStorePlatform.instance.setValue(
        'String',
        'flutter.$cloudUiModelsKey',
        jsonEncode(raw),
      );
      expect(
        prefs.getString(cloudUiModelsKey),
        isNot(contains('externally-replaced')),
      );
      await fail(book, request, const ModelHttpException(401, 'old request'));
      await prefs.reload();
      final latest = (await items(notifier)).first;
      expect(latest.key, 'externally-replaced');
      expect(latest.failedRequests, 0);
    },
  );

  test(
    'latest credential identity and current strategy protect replacement keys',
    () async {
      final (notifier, book) = await recorder();
      final request = await configFor(notifier);
      final p = (await notifier.readStored()).getProvider('channel')!;
      final changed = [
        for (final item in providerMultiKeyItemsFromProvider(p))
          if (item.id == 'one')
            {...item.toJson(), 'key': 'replacement'}
          else
            item.toJson(),
      ];
      await notifier.editProvider(
        providerId: p.id,
        customConfig: {...p.customConfig, 'multi_key_items': changed},
      );
      await fail(book, request, const ModelHttpException(401, 'old'));
      expect((await items(notifier)).first.failedRequests, 0);
      final current = await configFor(notifier);
      await notifier.editProvider(
        providerId: p.id,
        customConfig: {...p.customConfig, 'multi_key_strategy': 'random'},
      );
      await fail(book, current, const ModelHttpException(401, 'old strategy'));
      expect((await items(notifier)).first.failedRequests, 0);
    },
  );

  for (final separateChannel in [false, true]) {
    test(
      'nested compaction attributes only its own key: separateChannel=$separateChannel',
      () async {
        final (notifier, book) = await recorder();
        final parent = (await notifier.readStored()).getProvider('channel')!;
        final child = separateChannel
            ? _provider('summary-channel', strategy: 'exhaust')
            : parent;
        final prefs = await SharedPreferences.getInstance();
        final stored =
            jsonDecode(prefs.getString(cloudUiModelsKey)!)
                as Map<String, dynamic>;
        await prefs.setString(
          cloudUiModelsKey,
          jsonEncode({
            ...stored,
            'providers': [parent.toJson(), if (separateChannel) child.toJson()],
          }),
        );
        final settings = _settings(
          parent,
        ).copyWith(providers: [parent, if (separateChannel) child]);
        var parentRequests = 0;
        var childRequests = 0;
        final childRunner = KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => AgentApiClient(
            client: MockClient((_) async {
              childRequests++;
              return http.Response('{"error":"invalid child credential"}', 401);
            }),
          ),
        );
        final childAgent = BackgroundAgentService(
          loadRecentMessages: (_, _) async => [],
          loadSettings: () async => settings,
          traceStore: traces,
          keyFailureRecorder: book,
          executor:
              ({
                required config,
                required availableTools,
                required sessionId,
              }) => childRunner.executeApiCall(
                config: config,
                sessionId: sessionId,
                userText: null,
                responseProcessors: const [],
              ),
        );
        final task = TaskAgentRunner(
          loadSettings: () async => settings,
          keyFailureRecorder: book,
          summarizerFactory: () async => BackgroundContextSummarizer(
            childAgent,
            modelRef: '${child.id}:chat',
            contextTokens: 32768,
          ),
          executor:
              ({
                required config,
                required tools,
                required sessionId,
                required cancellation,
              }) async {
                await config.runtimeContext!.prepare(
                  config.messages,
                  force: true,
                );
                parentRequests++;
                return _reply;
              },
        );
        await expectLater(
          task.run(
            taskId: 'task',
            runId: 'run',
            transcript: 'latest',
            capabilities: const TaskAgentCapabilities(),
            preset: const TaskAgentPreset(),
            cancellation: KernelCancellation(),
            contextMessages: const [
              {'role': 'user', 'content': 'earlier task'},
              {'role': 'assistant', 'content': 'earlier progress'},
              {'role': 'user', 'content': 'latest task'},
            ],
          ),
          throwsA(isA<ModelHttpException>()),
        );
        expect(parentRequests, 0);
        expect(childRequests, 1);
        final latest = await notifier.readStored();
        expect(
          providerMultiKeyItemsFromProvider(
            latest.getProvider(child.id)!,
          ).first.failedRequests,
          1,
        );
        expect(
          (await items(notifier)).first.failedRequests,
          separateChannel ? 0 : 1,
        );
      },
    );
  }

  test(
    'concurrent failures read and patch inside the write transaction',
    () async {
      final (notifier, book) = await recorder();
      final request = await configFor(notifier);
      await Future.wait([
        fail(book, request, const ModelHttpException(401, 'a')),
        fail(book, request, const ModelHttpException(401, 'b')),
      ]);
      final stored = (await items(notifier)).first;
      expect(stored.failedRequests, 2);
      expect(stored.totalRequests, 2);
    },
  );

  for (final streaming in [false, true]) {
    test(
      'real transport failure is booked once after final model error: streaming=$streaming',
      () async {
        final (notifier, book) = await recorder();
        var requests = 0;
        final runner = KernelApiRunner.withAgentClientFactory(
          agentClientFactory: (_) => AgentApiClient(
            client: MockClient((_) async {
              requests++;
              return http.Response('{"error":"unauthorized"}', 401);
            }),
          ),
        );
        final config = await configFor(notifier);
        await expectLater(
          executeWithProviderKeyFailureRecording(
            config: config,
            recorder: book,
            execute: () => runner.executeApiCall(
              config: config,
              sessionId: 'c',
              userText: null,
              responseProcessors: const [],
              enableStreaming: streaming,
            ),
          ),
          throwsA(isA<ModelHttpException>()),
        );
        expect(requests, streaming ? 2 : 1);
        expect((await items(notifier)).first.failedRequests, 1);
      },
    );
  }

  test(
    'streaming fallback recovery and transient retries do not mark a key',
    () async {
      final (notifier, book) = await recorder();
      var requests = 0;
      final runner = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => AgentApiClient(
          client: MockClient((request) async {
            requests++;
            if (jsonDecode(request.body)['stream'] == true) {
              return http.Response(
                'data: {"error":{"message":"stream unsupported"}}\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              );
            }
            return http.Response(
              '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}',
              200,
            );
          }),
        ),
      );
      final config = await configFor(notifier);
      final result = await executeWithProviderKeyFailureRecording(
        config: config,
        recorder: book,
        execute: () => runner.executeApiCall(
          config: config,
          sessionId: 'c',
          userText: null,
          responseProcessors: const [],
          enableStreaming: true,
        ),
      );
      expect(result.replyText, 'ok');
      expect(requests, 2);
      var attempts = 0;
      await executeWithProviderKeyFailureRecording(
        config: config,
        recorder: book,
        execute: () => retryModelRound(
          cancellation: KernelCancellation(),
          wait: (_) async {},
          send: () async {
            if (++attempts < 3) throw const SocketException('offline');
            return _reply;
          },
        ),
      );
      expect(attempts, 3);
      expect((await items(notifier)).first.failedRequests, 0);
    },
  );

  test('only actual model network errors receive transport origin', () async {
    await expectLater(
      modelTransportRequest(() async => throw const SocketException('model')),
      throwsA(isA<SocketException>()),
    );
    await expectLater(
      modelTransportStream(
        Stream<int>.error(TimeoutException('body')),
      ).drain<void>(),
      throwsA(isA<TimeoutException>()),
    );
    await expectLater(
      modelTransportRequest(() async => throw StateError('local serializer')),
      throwsA(isA<StateError>()),
    );
  });
}
