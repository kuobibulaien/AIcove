import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/task_relay.dart';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/app_logger.dart' show TraceLogger;
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions, ToolCall;
import 'package:aicove_flutter/src/core/prompts/prompt_builtin_defaults.g.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_action.dart';
import 'package:aicove_flutter/src/features/agent_plugins/aicove_plugin.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_scope.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

class _ProbePlugin implements Plugin {
  _ProbePlugin(this.capture, {this.onResponse});
  final void Function(String)? onResponse;
  final void Function(PluginRequestInputs) capture;
  @override
  String get id => 'stage3_probe';
  @override
  bool get enabled => true;
  @override
  AicovePlugin get agentPlugin => AicovePlugin(
    id: id,
    name: id,
    capabilities: const {AppCapability.request, AppCapability.responses},
    setup: (registrar) {
      registrar.add(AppContributions.requestScope, (inputs) {
        capture(inputs);
        return _ProbeScope();
      });
      if (onResponse != null) {
        registrar.add(
          AppContributions.responseProcessor,
          (_) => ResponseFunction(id, (text) async {
            onResponse!(text);
            return PluginProcessResult(
              processedText: '$text!processed',
              events: const [],
            );
          }),
        );
      }
    },
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProbeScope extends PluginRequestScope {
  @override
  String get pluginId => 'stage3_probe';
  @override
  String get pluginName => pluginId;
  @override
  bool get active => true;
}

class _YieldAwareGenerator extends ProactiveReplyGenerator {
  _YieldAwareGenerator(super.ref, this.onReady);
  final void Function() onReady;

  @override
  Future<ApiConfig> prepare({
    required Conversation conversation,
    required String? reminder,
    DateTime? requestTime,
  }) async => (await super.prepare(
    conversation: conversation,
    reminder: reminder,
    requestTime: requestTime,
  )).copyWith(onYieldReady: (_) => onReady());
}

class _CallOnceClient extends AgentApiClient {
  var modelCalls = 0;

  @override
  Future<SendMessageRichResult> sendMessageRich({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    modelCalls++;
    if (modelCalls > 1) {
      throw StateError('call_user must yield before a second model request');
    }
    return const SendMessageRichResult(
      text: '',
      rawFinishReason: 'tool_calls',
      toolResults: [],
      toolCalls: [
        ToolCall(
          id: 'call_once',
          name: 'call_user',
          arguments: {'opening_line': '喂，想和你说说话'},
        ),
      ],
    );
  }
}

final _now = DateTime.utc(2026, 10, 12, 10, 5, 30);
const _model = 'openai:gpt-4o';
const _conv = 'conv_headless';
const _reminder = '用户一上午没说话，轻轻问候一下';

AppSettings _settings() =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      modelConfigs: {
        _model: const ModelConfig(chatCapabilities: ['tools', 'vision']),
      },
      imageGenerationEnabled: true,
      modelTypes: const {_model: 'chat', 'image-model': 'image'},
      callFlowSettings: const CallFlowSettings(mode: CallFlowMode.call),
      providers: const [
        ProviderAuth(
          id: 'openai',
          apiKeys: ['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
        ),
        ProviderAuth(
          id: 'image',
          apiKeys: ['image-key'],
          apiBaseUrl: 'https://image.invalid/v1',
          models: ['image-model'],
          visibleModels: ['image-model'],
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'gpt-4o': 'openai'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.AppDatabase database;
  late List<Override> overrides;
  late List<ApiConfig> sent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('stage3_generation_');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    addTearDown(() async {
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    });

    final t = _now.millisecondsSinceEpoch;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: _conv,
            title: '理',
            displayName: '理',
            personaPrompt: Value(
              PersonaPromptCodec.compose(userPrompt: '你是温柔的理。'),
            ),
            createdAt: t,
            updatedAt: t,
          ),
        );
    for (final (i, (role, text)) in [
      ('user', '早上好'),
      ('assistant', '早呀，今天想做什么？'),
    ].indexed) {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'm$i',
              conversationId: _conv,
              role: role,
              content: text,
              createdAt: t - 3600000 + i * 1000,
            ),
          );
    }

    sent = [];
    overrides = [
      databaseProvider.overrideWithValue(database),
      appSettingsProvider.overrideWith(() => _Settings(_settings())),
      requestClockProvider.overrideWithValue(() => _now),
      memoryKeeperProvider.overrideWith(
        (ref) => MemoryKeeperService(
          store: ref.read(memoryStoreProvider),
          loadMessages: (_) async => const [],
          compactedBoundaries: (_) async => const {},
          agentFactory: () => throw StateError('memory agent disabled'),
          allowed: (_) async => false,
        ),
      ),
      proactiveReplyExecutorProvider.overrideWithValue(({
        required config,
        required sessionId,
        required userText,
        required turnId,
      }) async {
        expect(config.responseProcessors, isEmpty);
        sent.add(config);
        return const ApiCallResult(
          replyText: '想你啦，在忙吗？',
          processedText: '想你啦，在忙吗？',
          pluginEvents: [],
          toolResults: [],
        );
      }),
    ];
  });

  ProviderContainer container({
    ProactiveReplyExecutor? executor,
    AppSettings? settings,
  }) {
    final value = ProviderContainer(
      overrides: [
        ...overrides,
        if (settings != null)
          appSettingsProvider.overrideWith(() => _Settings(settings)),
        if (executor != null)
          proactiveReplyExecutorProvider.overrideWithValue(executor),
      ],
    );
    addTearDown(value.dispose);
    return value;
  }

  Future<ProactiveDraft> draft(
    Future<ApiCallResult> Function(ApiConfig) reply,
  ) async {
    final value = container(
      executor:
          ({
            required config,
            required sessionId,
            required userText,
            required turnId,
          }) {
            expect(config.responseProcessors, isEmpty);
            return reply(config);
          },
    );
    final generator = value.read(proactiveReplyGeneratorProvider);
    return generator.generateDraft(
      conversation: (await generator.loadConversation(_conv))!,
      reminder: _reminder,
      turnId: 'ahead',
      requestTime: _now,
      allowCall: true,
    );
  }

  test(
    'copyWith preserves, replaces, and clears response processor snapshots',
    () async {
      final value = container();
      final generator = value.read(proactiveReplyGeneratorProvider);
      final config = await value
          .read(chatSendServiceProvider)
          .prepareApiConfig(
            conv: (await generator.loadConversation(_conv))!,
            history: const [],
            userText: null,
          );
      expect(config.responseProcessors, isNotEmpty);
      expect(
        config.copyWith().responseProcessors,
        same(config.responseProcessors),
      );
      final replacement = [
        ResponseFunction(
          'replacement',
          (text) async =>
              PluginProcessResult(processedText: text, events: const []),
        ),
      ];
      expect(
        config.copyWith(responseProcessors: replacement).responseProcessors,
        same(replacement),
      );
      final clean = config.copyWith(responseProcessors: const []);
      expect(clean.responseProcessors, isEmpty);
      expect(clean.copyWith(modelTemperature: 0.4).responseProcessors, isEmpty);
      expect(config.responseProcessors, isNotEmpty);
    },
  );

  test(
    'empty raw is not replaced with display-only text in generated drafts',
    () async {
      final value = container(
        executor:
            ({
              required config,
              required sessionId,
              required userText,
              required turnId,
            }) async {
              expect(config.responseProcessors, isEmpty);
              return const ApiCallResult(
                rawReplyText: '',
                replyText: '<image>display-only</image>',
                processedText: 'processed-only',
                pluginEvents: [],
                toolResults: [],
              );
            },
      );
      final generator = value.read(proactiveReplyGeneratorProvider);
      final conversation = (await generator.loadConversation(_conv))!;
      expect(
        await generator.generate(
          conversation: conversation,
          reminder: _reminder,
          turnId: 'empty-raw',
        ),
        isEmpty,
      );
      final result = await generator.generateDraft(
        conversation: conversation,
        reminder: _reminder,
        turnId: 'empty-draft',
        requestTime: _now,
        allowCall: true,
      );
      expect(result.action, ProactiveAction.sendMessage);
      expect(result.text, isEmpty);
    },
  );

  test(
    'real task relay generates raw and runs delivery processors once',
    () async {
      final inputs = <String>[];
      final manager = PluginManager()
        ..register(_ProbePlugin((_) {}, onResponse: inputs.add));
      Object? generationError;
      const raw = '<think>任务思考</think>任务办好了<sticker>小猫</sticker>';
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': raw},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      final value = ProviderContainer(
        overrides: [
          ...overrides,
          appSettingsProvider.overrideWith(
            () => _Settings(
              _settings().copyWith(
                ttsEnabled: false,
                imageGenerationEnabled: false,
                streamSegmentDelaySeconds: 0,
              ),
            ),
          ),
          pluginManagerProvider.overrideWithValue(manager),
          proactiveReplyExecutorProvider.overrideWithValue(({
            required config,
            required sessionId,
            required userText,
            required turnId,
          }) async {
            expect(config.responseProcessors, isEmpty);
            final result =
                await KernelApiRunner.withAgentClientFactory(
                      agentClientFactory: (timeout) =>
                          AgentApiClient(client: client, timeout: timeout),
                    )
                    .executeApiCall(
                      config: config,
                      sessionId: sessionId,
                      userText: userText,
                      responseProcessors: config.responseProcessors,
                    )
                    .catchError((Object error) {
                      generationError = error;
                      throw error;
                    });
            expect(inputs, isEmpty);
            expect(result.rawReplyText, '任务办好了<sticker>小猫</sticker>');
            return result;
          }),
        ],
      );
      addTearDown(value.dispose);
      final service = await value.read(taskAgentServiceProvider.future);
      final store = value.read(agentTaskStoreProvider);
      await store.create(
        id: 'relay',
        requestKey: null,
        conversationId: _conv,
        instruction: 'work',
      );
      final receipt = (await store.finish(
        'relay',
        from: {AgentTaskStatus.queued},
        to: AgentTaskStatus.done,
        executorDevice: 'test',
        summary: 'done',
      ))!;
      await service.writeReceipt(receipt);
      await store.markReceiptWritten(receipt.task.id, receipt.block.receiptId);
      await service.deliver(receipt.block.receiptId, receipt.block);
      expect(generationError, isNull);
      expect(inputs, ['任务办好了<sticker>小猫</sticker>']);
      final messages = await (database.select(
        database.messages,
      )..where((m) => m.role.equals('assistant'))).get();
      final relayed = messages
          .where(
            (m) =>
                m.rawPayload != null &&
                (jsonDecode(m.rawPayload!) as Map)[taskRelayReceiptKey] ==
                    receipt.block.receiptId,
          )
          .single;
      expect(relayed.content, '任务办好了<sticker>小猫</sticker>');
      expect(await store.pendingDeliveries(), isEmpty);
      await service.deliver(receipt.block.receiptId, receipt.block);
      expect(inputs, hasLength(1));
    },
  );

  test(
    'proactive uses inline images, normal chat keeps the stable draw tool',
    () async {
      final value = container();
      final generator = value.read(proactiveReplyGeneratorProvider);
      final conversation = (await generator.loadConversation(_conv))!;
      final ordinary = await value
          .read(chatSendServiceProvider)
          .prepareApiConfig(
            conv: conversation,
            history: const [],
            userText: null,
          );
      expect(jsonEncode(ordinary.tools), contains('draw_image'));
      expect(ordinary.responseProcessors, isNotEmpty);
      expect(
        ordinary.copyWith().responseProcessors,
        same(ordinary.responseProcessors),
      );
      final prepared = await generator.prepare(
        conversation: conversation,
        reminder: _reminder,
      );
      expect(prepared.tools ?? [], isEmpty);
      expect(prepared.responseProcessors, isEmpty);
      expect(
        jsonEncode(
          prepared.messages.where((m) => m['role'] == 'system').toList(),
        ),
        contains('<image>'),
      );
      final hint = PromptBuiltinDefaults.requireTemplate(
        'auto_reply.reach_out.image_hint',
      );
      expect(prepared.messages.last['role'], 'user');
      expect(prepared.messages.last['content'], contains(hint));
      expect(
        (prepared.messages.last['content'] as String).split(hint),
        hasLength(2),
      );
    },
  );

  test('disabled drawing does not add an image hint', () async {
    final value = container(
      settings: _settings().copyWith(imageGenerationEnabled: false),
    );
    final generator = value.read(proactiveReplyGeneratorProvider);
    final prepared = await generator.prepare(
      conversation: (await generator.loadConversation(_conv))!,
      reminder: _reminder,
    );
    expect(
      jsonEncode(prepared.messages),
      isNot(
        contains(
          PromptBuiltinDefaults.requireTemplate(
            'auto_reply.reach_out.image_hint',
          ),
        ),
      ),
    );
  });

  test('a role with drawing disabled does not get an image hint', () async {
    final value = container();
    final generator = value.read(proactiveReplyGeneratorProvider);
    final conversation = (await generator.loadConversation(
      _conv,
    ))!.copyWith(enabledPlugins: const <String>[]);
    final prepared = await generator.prepare(
      conversation: conversation,
      reminder: _reminder,
    );
    expect(
      jsonEncode(prepared.messages),
      isNot(
        contains(
          PromptBuiltinDefaults.requireTemplate(
            'auto_reply.reach_out.image_hint',
          ),
        ),
      ),
    );
    expect(prepared.tools ?? [], isEmpty);
  });

  test(
    'request inputs carry their owner without needing chat history',
    () async {
      final inputs = <PluginRequestInputs>[];
      final value = container();
      final generator = value.read(proactiveReplyGeneratorProvider);
      final conversation = (await generator.loadConversation(_conv))!;
      final manager = value.read(pluginManagerProvider);
      final probe = _ProbePlugin(inputs.add);
      manager.register(probe);
      addTearDown(() => manager.unregister(probe.id));
      final send = value.read(chatSendServiceProvider);
      await send.prepareApiConfig(
        conv: conversation,
        history: const [],
        userText: null,
        conversationId: ' $_conv ',
      );
      expect(inputs.last.conversationId, _conv);
      expect(inputs.last.history, isEmpty);
      expect(inputs.last.useStableImageRoute, isTrue);
      await send.prepareApiConfig(
        conv: conversation,
        history: const [],
        userText: null,
        forceInlineImageRoute: true,
      );
      expect(inputs.last.conversationId, _conv);
      expect(inputs.last.useFastImageRoute, isTrue);
      expect(inputs.last.useStableImageRoute, isFalse);
    },
  );

  test(
    'a reminder already containing image instructions is not duplicated',
    () async {
      final value = container();
      final generator = value.read(proactiveReplyGeneratorProvider);
      const reminder = '想分享就用 <image>猫</image>';
      final prepared = await generator.prepare(
        conversation: (await generator.loadConversation(_conv))!,
        reminder: reminder,
      );
      expect(prepared.messages.last['content'], contains(reminder));
      expect(
        prepared.messages.last['content'],
        isNot(
          contains(
            PromptBuiltinDefaults.requireTemplate(
              'auto_reply.reach_out.image_hint',
            ),
          ),
        ),
      );
    },
  );

  test('a first proactive reminder works without chat history', () async {
    await database.delete(database.messages).go();
    final value = container();
    final generator = value.read(proactiveReplyGeneratorProvider);
    final conversation = (await generator.loadConversation(_conv))!;
    final prepared = await generator.prepare(
      conversation: conversation,
      reminder: _reminder,
    );
    expect(prepared.messages.last['content'], contains(_reminder));
    await expectLater(
      generator.prepare(conversation: conversation, reminder: '  '),
      throwsStateError,
    );
    await expectLater(
      generator.prepare(conversation: conversation, reminder: null),
      throwsStateError,
    );
  });

  test(
    'the draft call tool is read-only and yields only after a valid opening',
    () async {
      var yields = 0;
      final result = await draft((config) async {
        final tool = config.boundTools!.single;
        expect(tool.effect, ToolEffect.readPrivate);
        expect(config.onYieldReady, isNotNull);
        config.onYieldReady!(({bool enabled = true}) {
          if (enabled) yields++;
          return true;
        });
        await tool.handler({'opening_line': '  '});
        expect(yields, 0);
        await tool.handler({'opening_line': ' 喂，吃饭了吗 '});
        expect(yields, 1);
        return const ApiCallResult(
          replyText: '',
          processedText: '',
          pluginEvents: [],
          toolResults: [],
        );
      });
      expect(result.isCall, isTrue);
      expect(result.text, '喂，吃饭了吗');
    },
  );

  test(
    'real AgentLoop yields a call draft before a second model request',
    () async {
      final client = _CallOnceClient();
      final runner = ChatSendApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
      );
      late ApiCallResult executed;
      final result = await draft((config) async {
        executed = await runner.executeApiCall(
          config: config,
          sessionId: _conv,
          userText: _reminder,
          turnId: 'real_call_yield',
          responseProcessors: const [],
        );
        return executed;
      });

      expect(result.isCall, isTrue);
      expect(result.text, '喂，想和你说说话');
      expect(client.modelCalls, 1);
      expect(executed.stopReason, 'steered');
      expect(executed.toolCalls.single.name, 'call_user');
      expect(executed.rawToolResults, hasLength(1));
    },
  );

  test('denied tool calls cannot be recovered as successful calls', () async {
    final result = await draft(
      (_) async => const ApiCallResult(
        replyText: '先发消息吧',
        processedText: '先发消息吧',
        pluginEvents: [],
        toolResults: [
          {'tool_call_id': 'denied', 'content': 'denied'},
        ],
        toolCalls: [
          ToolCall(
            id: 'denied',
            name: 'call_user',
            arguments: {'opening_line': '不该打出'},
          ),
        ],
      ),
    );
    expect(result.isCall, isFalse);
    expect(result.text, '先发消息吧');
  });

  test(
    'legacy tool-call-only executors still recover the opening line',
    () async {
      final result = await draft(
        (_) async => const ApiCallResult(
          replyText: '',
          processedText: '',
          pluginEvents: [],
          toolResults: [],
          toolCalls: [
            ToolCall(
              id: 'legacy',
              name: 'call_user',
              arguments: {'opening_line': '旧执行器开场'},
            ),
          ],
        ),
      );
      expect(result.isCall, isTrue);
      expect(result.text, '旧执行器开场');
    },
  );

  test(
    'draft call binding retains the existing yield-ready callback',
    () async {
      var ready = 0;
      var yielded = 0;
      final value = ProviderContainer(
        overrides: [
          ...overrides,
          proactiveReplyGeneratorProvider.overrideWith(
            (ref) => _YieldAwareGenerator(ref, () => ready++),
          ),
          proactiveReplyExecutorProvider.overrideWithValue(({
            required config,
            required sessionId,
            required userText,
            required turnId,
          }) async {
            config.onYieldReady!(({bool enabled = true}) {
              if (enabled) yielded++;
              return true;
            });
            await config.boundTools!.single.handler({'opening_line': '来电开场'});
            return const ApiCallResult(
              replyText: '',
              processedText: '',
              pluginEvents: [],
              toolResults: [],
            );
          }),
        ],
      );
      addTearDown(value.dispose);
      final generator = value.read(proactiveReplyGeneratorProvider);
      final result = await generator.generateDraft(
        conversation: (await generator.loadConversation(_conv))!,
        reminder: _reminder,
        turnId: 'callback',
        requestTime: _now,
        allowCall: true,
      );
      expect(ready, 1);
      expect(yielded, 1);
      expect(result.isCall, isTrue);
    },
  );

  test('buildCallUserTool records only valid in-memory openings', () async {
    final lines = <String>[];
    final tool = buildCallUserTool(onCall: lines.add);
    await tool.handler({'opening_line': 123});
    await tool.handler({'opening_line': '  '});
    expect(lines, isEmpty);
    await tool.handler({'opening_line': '  你好  '});
    expect(lines, ['你好']);
  });
}
