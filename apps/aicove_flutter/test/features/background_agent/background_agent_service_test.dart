import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_agent_definition.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_context_spec.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/services/api_runner_variants.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/tool_parameter.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

AppSettings _buildTestSettings() {
  const modelRef = 'openai:gpt-3.5-turbo';
  return const AppSettings(
    ttsEnabled: false,
    defaultModelName: modelRef,
    defaultPersonaPrompt: '',
    modelList: <String>[modelRef],
    allKnownModels: <String>[modelRef],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{
      modelRef: ModelConfig(chatCapabilities: <String>['tools']),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['gpt-3.5-turbo'],
        visibleModels: <String>['gpt-3.5-turbo'],
      ),
    ],
    modelProviderMap: <String, String>{
      modelRef: 'openai',
      'gpt-3.5-turbo': 'openai',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: true,
    defaultChatModels: <String>[modelRef],
  );
}

class _StubToolPlugin extends BasePlugin {
  _StubToolPlugin({
    required String id,
    required this.tools,
  }) : super(
          metadata: PluginMetadata(
            id: id,
            name: id,
            description: 'test plugin',
            version: '1.0.0',
            author: 'test',
            icon: Icons.extension,
          ),
        );

  final List<AITool> tools;

  @override
  bool get enabled => true;

  @override
  List<AITool> getTools() => tools;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async =>
      null;

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(
        processedText: text,
        events: const <PluginEvent>[],
      );
}

class _SequencedToolCallClient extends http.BaseClient {
  int callCount = 0;
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      return _json(500, <String, dynamic>{'error': 'request type unsupported'});
    }
    callCount += 1;
    payloads.add(jsonDecode(request.body) as Map<String, dynamic>);

    if (callCount == 1) {
      return _json(
        200,
        <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{
                'role': 'assistant',
                'content': '',
                'tool_calls': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'call_memory_1',
                    'type': 'function',
                    'function': <String, dynamic>{
                      'name': 'memory_lookup',
                      'arguments': '{}',
                    },
                  },
                ],
              },
            },
          ],
        },
      );
    }

    return _json(
      200,
      <String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'role': 'assistant',
              'content': '记忆整理完成',
            },
          },
        ],
      },
    );
  }

  Future<http.StreamedResponse> _json(int statusCode, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}

AITool _buildTool(
    String name, Future<String?> Function(Map<String, dynamic>) handler) {
  return AITool(
    name: name,
    description: 'test tool $name',
    parameters: const <String, ToolParameter>{},
    handler: handler,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundAgentService', () {
    test('按上下文配置过滤消息并按白名单收集工具', () async {
      final pluginManager = PluginManager()
        ..register(
          _StubToolPlugin(
            id: 'memory',
            tools: <AITool>[
              _buildTool('memory_lookup', (_) async => '{"ok":true}'),
            ],
          ),
        )
        ..register(
          _StubToolPlugin(
            id: 'trigger',
            tools: <AITool>[
              _buildTool('delete_trigger', (_) async => '{"ok":true}'),
            ],
          ),
        );

      ApiConfig? capturedConfig;
      List<AITool>? capturedTools;
      final tempDir =
          await Directory.systemTemp.createTemp('bg_agent_trace_prepare_');
      final traceStore = TraceStore(rootDirResolver: () async => tempDir);
      addTearDown(() async {
        traceStore.debugResetForTest();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final service = BackgroundAgentService(
        loadRecentMessages: (_, __) async => <Message>[
          Message.text(
            id: 'm1',
            role: 'user',
            content: '我喜欢喝美式',
            createdAt: DateTime(2026, 3, 18, 9, 0),
          ),
          Message.text(
            id: 'm2',
            role: 'assistant',
            content: '记住了',
            createdAt: DateTime(2026, 3, 18, 9, 1),
          ),
          Message.text(
            id: 'm3',
            role: 'user',
            content: '别放糖',
            createdAt: DateTime(2026, 3, 18, 9, 2),
          ),
        ],
        loadSettings: () async => _buildTestSettings(),
        readPluginManager: () => pluginManager,
        requestConfigResolver: ({
          required AppSettings settings,
          required String? modelRef,
        }) async {
          return const BackgroundAgentRequestConfig(
            modelFullId: 'openai:gpt-3.5-turbo',
            providerApiBase: 'https://api.openai.com/v1',
            providerApiKey: 'test-key',
            customConfig: <String, dynamic>{},
            modelTemperature: null,
            modelTopP: null,
            modelContextMessageLimit: null,
          );
        },
        executor: ({
          required ApiConfig config,
          required List<AITool> availableTools,
          required String sessionId,
          required int maxRounds,
        }) async {
          capturedConfig = config;
          capturedTools = availableTools;
          return const ApiCallResult(
            replyText: '',
            processedText: 'done',
            pluginEvents: <PluginEvent>[],
            toolResults: <Map<String, dynamic>>[],
          );
        },
        sessionIdFactory: (_) => 'bg_test_session',
        traceStore: traceStore,
      );

      final result = await service.run(
        definition: const BackgroundAgentDefinition(
          id: 'memory_agent',
          name: '记忆整理',
          objectivePrompt: '提取长期记忆',
          contextSpec: BackgroundContextSpec(
            lastMessages: 3,
            includeUser: true,
            includeAssistant: false,
            includeTimestamps: true,
          ),
          allowedToolNames: <String>['memory_lookup'],
        ),
        conversationId: 'conv_1',
        extraInstruction: '只输出关键信息',
      );

      expect(result.sessionId, 'bg_test_session');
      expect(result.usedMessages.map((m) => m.role), everyElement('user'));
      expect(capturedTools?.map((t) => t.name), <String>['memory_lookup']);
      expect(capturedConfig?.tools?.length, 1);
      expect(capturedConfig?.traceContext, isNotNull);
      expect(capturedConfig?.messages.first['role'], 'system');
      expect(
        capturedConfig?.messages.first['content'],
        allOf(contains('提取长期记忆'), contains('只输出关键信息')),
      );
      expect(capturedConfig?.messages.skip(1).length, 2);

      await traceStore.waitForPendingWrites();
      final events = await traceStore.readEventsByTraceId(
        capturedConfig!.traceContext!.traceId,
      );
      expect(
        events.map((event) => event.stage),
        containsAll(<String>[
          TraceStage.turnStarted.value,
          TraceStage.historyPrepared.value,
          TraceStage.apiConfigReady.value,
          TraceStage.turnCompleted.value,
        ]),
      );

      final apiConfigEvent = events.firstWhere(
        (event) => event.stage == TraceStage.apiConfigReady.value,
      );
      final payloadEnvelope = await traceStore.readPayloadByRef(
        apiConfigEvent.payloadRef,
      );
      final payload = payloadEnvelope?['payload'] as Map<String, dynamic>? ??
          const <String, dynamic>{};
      final runtimeContext =
          payload['runtimeContext'] as Map<String, dynamic>? ??
              const <String, dynamic>{};
      final promptAssembly =
          payload['promptAssembly'] as Map<String, dynamic>? ??
              const <String, dynamic>{};
      expect(runtimeContext['requestSource'], TraceKind.backgroundAgent.value);
      expect(promptAssembly['systemPrompt'], contains('只输出关键信息'));
      expect(payload['rawContext'], contains('我喜欢喝美式'));
    });

    for (final (variant, createRunner) in apiRunnerVariants) {
    test('[$variant] 通过 availableTools 可在无插件执行链下完成工具调用', () async {
      final client = _SequencedToolCallClient();
      final runner = createRunner(
        agentClientFactory: (timeout) => AgentApiClient(
          client: client,
          timeout: timeout,
        ),
      );
      final pluginManager = PluginManager()
        ..register(
          _StubToolPlugin(
            id: 'memory',
            tools: <AITool>[
              _buildTool('memory_lookup', (_) async {
                return jsonEncode(<String, dynamic>{
                  'success': true,
                  'memory': '用户偏好无糖美式',
                });
              }),
            ],
          ),
        );
      TraceStore.instance.debugResetForTest();
      addTearDown(TraceStore.instance.debugResetForTest);
      TraceContext? capturedTraceContext;

      final service = BackgroundAgentService(
        loadRecentMessages: (_, __) async => <Message>[
          Message.text(
            id: 'm1',
            role: 'user',
            content: '我喜欢无糖美式',
            createdAt: DateTime(2026, 3, 18, 10, 0),
          ),
        ],
        loadSettings: () async => _buildTestSettings(),
        readPluginManager: () => pluginManager,
        requestConfigResolver: ({
          required AppSettings settings,
          required String? modelRef,
        }) async {
          return const BackgroundAgentRequestConfig(
            modelFullId: 'openai:gpt-3.5-turbo',
            providerApiBase: 'https://api.openai.com/v1',
            providerApiKey: 'test-key',
            customConfig: <String, dynamic>{},
            modelTemperature: null,
            modelTopP: null,
            modelContextMessageLimit: null,
          );
        },
        executor: ({
          required ApiConfig config,
          required List<AITool> availableTools,
          required String sessionId,
          required int maxRounds,
        }) {
          capturedTraceContext = config.traceContext;
          return runner.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: null,
            effectivePlugins: const [],
            availableTools: availableTools,
            maxRounds: maxRounds,
            traceContext: config.traceContext,
          );
        },
        sessionIdFactory: (_) => 'bg_memory_session',
      );

      final result = await service.run(
        definition: const BackgroundAgentDefinition(
          id: 'memory_agent',
          name: '记忆整理',
          objectivePrompt: '调用工具读取记忆并给出总结',
          contextSpec: BackgroundContextSpec(lastMessages: 1),
          allowedToolNames: <String>['memory_lookup'],
          maxRounds: 2,
        ),
        conversationId: 'conv_2',
      );

      expect(client.callCount, 2);
      expect(
          result.toolCalls.map((call) => call.name), <String>['memory_lookup']);
      expect(result.text, contains('记忆整理完成'));
      await TraceStore.instance.waitForPendingWrites();
      expect(capturedTraceContext, isNotNull);

      final events = await TraceStore.instance.readEventsByTraceId(
        capturedTraceContext!.traceId,
      );
      expect(
        events.map((event) => event.stage),
        containsAll(<String>[
          TraceStage.turnStarted.value,
          TraceStage.historyPrepared.value,
          TraceStage.apiConfigReady.value,
          TraceStage.roundRequestBuilt.value,
          TraceStage.modelRequestSent.value,
          TraceStage.modelResponseReceived.value,
          TraceStage.toolCallDetected.value,
          TraceStage.toolExecFinished.value,
          TraceStage.finalReplyReady.value,
          TraceStage.turnCompleted.value,
        ]),
      );
    });
    }

    test('传入指定上下文时不再回退到最近消息加载器', () async {
      ApiConfig? capturedConfig;

      final service = BackgroundAgentService(
        loadRecentMessages: (_, __) async {
          fail('传入 contextMessages 后不应再调用 loadRecentMessages');
        },
        loadSettings: () async => _buildTestSettings(),
        readPluginManager: () => PluginManager(),
        requestConfigResolver: ({
          required AppSettings settings,
          required String? modelRef,
        }) async {
          return const BackgroundAgentRequestConfig(
            modelFullId: 'openai:gpt-3.5-turbo',
            providerApiBase: 'https://api.openai.com/v1',
            providerApiKey: 'test-key',
            customConfig: <String, dynamic>{},
            modelTemperature: null,
            modelTopP: null,
            modelContextMessageLimit: null,
          );
        },
        executor: ({
          required ApiConfig config,
          required List<AITool> availableTools,
          required String sessionId,
          required int maxRounds,
        }) async {
          capturedConfig = config;
          return const ApiCallResult(
            replyText: '',
            processedText: 'done',
            pluginEvents: <PluginEvent>[],
            toolResults: <Map<String, dynamic>>[],
          );
        },
      );

      final result = await service.run(
        definition: const BackgroundAgentDefinition(
          id: 'memory_agent',
          name: '记忆整理',
          objectivePrompt: '提取长期记忆',
          contextSpec: BackgroundContextSpec(
            includeUser: true,
            includeAssistant: true,
            includeTimestamps: true,
          ),
        ),
        conversationId: 'conv_override',
        contextMessages: <Message>[
          Message.text(
            id: 'm_context_1',
            role: 'user',
            content: '这是指定上下文',
            createdAt: DateTime(2026, 3, 18, 8, 0),
          ),
        ],
      );

      expect(result.usedMessages, hasLength(1));
      expect(result.usedMessages.single.id, 'm_context_1');
      expect(
        (capturedConfig?.messages[1]['content'] as String?) ?? '',
        contains('[2026-03-18 08:00]'),
      );
      expect(capturedConfig?.traceContext, isNotNull);
    });

    test('对话以 assistant 结尾时请求仍以一条 user 消息结尾', () async {
      ApiConfig? capturedConfig;

      final service = BackgroundAgentService(
        loadRecentMessages: (_, __) async => const <Message>[],
        loadSettings: () async => _buildTestSettings(),
        readPluginManager: () => PluginManager(),
        requestConfigResolver: ({
          required AppSettings settings,
          required String? modelRef,
        }) async {
          return const BackgroundAgentRequestConfig(
            modelFullId: 'openai:gpt-3.5-turbo',
            providerApiBase: 'https://api.openai.com/v1',
            providerApiKey: 'test-key',
            customConfig: <String, dynamic>{},
            modelTemperature: null,
            modelTopP: null,
            modelContextMessageLimit: null,
          );
        },
        executor: ({
          required ApiConfig config,
          required List<AITool> availableTools,
          required String sessionId,
          required int maxRounds,
        }) async {
          capturedConfig = config;
          return const ApiCallResult(
            replyText: '',
            processedText: '{}',
            pluginEvents: <PluginEvent>[],
            toolResults: <Map<String, dynamic>>[],
          );
        },
      );

      await service.run(
        definition: const BackgroundAgentDefinition(
          id: 'auto_reply_scheduler',
          name: '主动回复触发判断',
          objectivePrompt: '决定是否主动回复',
          contextSpec: BackgroundContextSpec(includeTimestamps: true),
        ),
        conversationId: 'preset_nahida',
        contextMessages: <Message>[
          Message.text(
            id: 'u1',
            role: 'user',
            content: '我去洗澡了',
            createdAt: DateTime(2026, 9, 23, 14, 40),
          ),
          Message.text(
            id: 'a1',
            role: 'assistant',
            content: '好，等你回来',
            createdAt: DateTime(2026, 9, 23, 14, 41),
          ),
        ],
      );

      final messages = capturedConfig!.messages;
      expect(messages.map((m) => m['role']), <String>['system', 'user']);
      expect(
        messages.last['content'],
        allOf(
          contains('用户：[2026-09-23 14:40]: 我去洗澡了'),
          contains('角色：[2026-09-23 14:41]: 好，等你回来'),
        ),
      );
    });
    test('后台执行器默认走旧执行器，开关为真时为内核执行器', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(kAgentKernelBackground, isFalse);
      expect(container.read(backgroundApiRunnerProvider), isA<ChatSendApiRunner>());
      expect(createApiRunner(useKernel: true), isA<KernelApiRunner>());
      expect(createApiRunner(useKernel: false), isA<ChatSendApiRunner>());
    });

    test('内核执行器只在轮次上限小于 1 时回退旧执行器', () {
      expect(KernelApiRunner.needsLegacyRunner(maxRounds: 0), isTrue);
      expect(KernelApiRunner.needsLegacyRunner(maxRounds: 1), isFalse);
    });
  });
}
