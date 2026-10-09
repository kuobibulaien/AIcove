// Differential tests for ADR0064 batch 1b: each scenario runs on the legacy
// runner and on the kernel runner; requests sent, callbacks, trace stages and
// every ApiCallResult field must match.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions, ToolCall;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show KernelScope;
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';

import 'api_runner_variants.dart';

/// A streamed response: deltas are delivered, then [outcome] is returned
/// (a [SendMessageRichResult]) or thrown.
class _Stream {
  const _Stream(this.deltas, this.outcome);
  final List<String> deltas;
  final Object outcome;
}

class _ScriptedClient extends AgentApiClient {
  _ScriptedClient(this.steps) : super();

  final List<Object> steps;
  final List<Object?> requests = [];
  final List<String> modes = [];

  Object _next(List<Map<String, dynamic>> messages, String mode) {
    requests.add(jsonDecode(jsonEncode(messages)));
    modes.add(mode);
    if (steps.isEmpty) throw StateError('no scripted step');
    return steps.removeAt(0);
  }

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
    Map<String, dynamic>? toolPrefs,
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
    final step = _next(messages, 'rich:$userText');
    if (step is SendMessageRichResult) return step;
    throw step;
  }

  @override
  Future<SendMessageRichResult> sendMessageRichStream({
    required String agentId,
    required String sessionId,
    required String modelFullId,
    required List<Map<String, dynamic>> messages,
    required String userText,
    double? temperature,
    double? topP,
    String? token,
    Map<String, dynamic>? toolPrefs,
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    ProviderChatRequestOptions? requestOptions,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    final step = _next(messages, 'stream:$userText');
    if (step is _Stream) {
      step.deltas.forEach(onTextDelta ?? (_) {});
      final outcome = step.outcome;
      if (outcome is SendMessageRichResult) {
        if (outcome.toolCalls.isNotEmpty) onToolCallsDetected?.call();
        return outcome;
      }
      throw outcome;
    }
    if (step is SendMessageRichResult) return step;
    throw step;
  }
}

class _SuffixPlugin extends BasePlugin {
  _SuffixPlugin()
      : super(
          metadata: PluginMetadata(
            id: 'suffix',
            name: 'suffix',
            description: 'test plugin',
            version: '1.0.0',
            author: 'test',
            icon: Icons.extension,
          ),
        );

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async =>
      null;

  @override
  Future<PluginProcessResult> processResponse(String text) async =>
      PluginProcessResult(
        processedText: '$text[p]',
        events: [PluginEvent(pluginId: 'suffix', type: 'seen', data: {'n': text.length}, id: 'e1')],
      );
}

class _LoggingPlugin extends _SuffixPlugin {
  _LoggingPlugin(this.log);
  final List<String> log;

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    log.add('processResponse');
    return super.processResponse(text);
  }
}

class _Context implements RuntimeContextPort {
  final List<bool> calls = [];
  @override
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages, {
    bool force = false,
  }) async {
    calls.add(force);
    return messages;
  }
}

SendMessageRichResult _text(String text, {List<Map<String, dynamic>> hidden = const []}) =>
    SendMessageRichResult(text: text, toolResults: const [], hiddenThoughtParts: hidden);

SendMessageRichResult _calls(
  String text,
  List<ToolCall> calls, {
  Map<String, dynamic>? raw,
}) =>
    SendMessageRichResult(
      text: text,
      toolResults: const [],
      toolCalls: calls,
      rawResponse: raw,
    );

class _Scenario {
  _Scenario({
    required this.name,
    required this.steps,
    this.modelFullId = 'openai:gpt-test',
    this.stream = false,
    this.maxRounds = 5,
    this.useBoundTools = false,
    this.withPlugin = false,
    this.withContext = false,
    this.toolNames = const ['lookup', 'note'],
    this.fastMode = false,
  });

  final String name;
  final List<Object> Function() steps;
  final String modelFullId;
  final bool stream;
  final int maxRounds;
  final bool useBoundTools;
  final bool withPlugin;
  final bool withContext;
  final List<String> toolNames;
  final bool fastMode;
}

Future<Map<String, Object?>> _runScenario(
  RunnerFactory create,
  _Scenario sc,
) async {
  TraceStore.instance.debugResetForTest();
  final client = _ScriptedClient(sc.steps());
  final executions = <String>[];
  AITool tool(String name) => AITool(
        name: name,
        description: 'test',
        parameters: const {},
        handler: (args) async {
          // Start/end around a yield exposes serial vs concurrent batches.
          executions.add('start:$name:${args['tag']}');
          await Future<void>.delayed(Duration.zero);
          executions.add('end:$name:${args['tag']}');
          return 'result-of-$name';
        },
      );
  final tools = [for (final name in sc.toolNames) tool(name)];
  final base = mapUiModelsToAppSettings({});
  final settings = sc.fastMode
      ? base.copyWith(
          callFlowSettings: const CallFlowSettings(mode: CallFlowMode.fast),
        )
      : base;
  final context = sc.withContext ? _Context() : null;
  final deltas = <String>[];
  final executing = <String>[];
  var fallbacks = 0;
  var observed = 0;
  ApiCallResult? result;
  String? error;
  try {
    result = await create(agentClientFactory: (_) => client).executeApiCall(
      config: ApiConfig(
        settings: settings,
        modelFullId: sc.modelFullId,
        providerApiBase: 'https://invalid.test',
        customConfig: const {},
        toolPrefs: const {},
        messages: const [
          {'role': 'user', 'content': '开始'},
        ],
        tools: [for (final t in tools) t.toOpenAISchema()],
        boundTools: sc.useBoundTools ? tools : null,
        runtimeContext: context,
      ),
      sessionId: 'session',
      userText: '开始',
      effectivePlugins: sc.withPlugin ? [_SuffixPlugin()] : const [],
      availableTools: sc.useBoundTools ? null : tools,
      maxRounds: sc.maxRounds,
      enableStreaming: sc.stream,
      onStreamTextDelta: deltas.add,
      onStreamingFallback: () => fallbacks++,
      onStreamToolCallObserved: () => observed++,
      onToolExecuting: executing.add,
      traceContext: const TraceContext(
        traceId: 'trace',
        sessionId: 'session',
        turnId: 'turn',
      ),
    );
  } catch (e) {
    error = '${e.runtimeType}:$e';
  }
  return {
    'requests': client.requests,
    'modes': client.modes,
    'executions': executions,
    'executing': executing,
    'deltas': deltas,
    'fallbacks': fallbacks,
    'observed': observed,
    'contextCalls': context?.calls,
    'error': error,
    'trace': [
      for (final e in TraceStore.instance.debugInMemoryEvents())
        '${e.roundIndex}:${e.stage}:${e.status}',
    ],
    if (result != null)
      'result': {
        'raw': result.rawReplyText,
        'reply': result.replyText,
        'processed': result.processedText,
        'hidden': result.hiddenThoughtParts,
        'toolCalls': [
          for (final c in result.toolCalls)
            [c.id, c.name, c.arguments, c.thoughtSignature],
        ],
        'rawToolResults': [
          for (final r in result.rawToolResults) [r.toolCallId, r.name, r.result],
        ],
        'toolResults': result.toolResults,
        'events': [for (final e in result.pluginEvents) [e.pluginId, e.type, e.data]],
        'contents': result.pluginContents.length,
        'audio': result.toolAudioResults.length,
      },
  };
}

final _scenarios = <_Scenario>[
  _Scenario(name: '无工具直接回答', steps: () => [_text('你好')]),
  _Scenario(
    name: '原生工具两轮，插件后处理',
    withPlugin: true,
    steps: () => [
      _calls('我查一下', const [
        ToolCall(id: 'c1', name: 'lookup', arguments: {'q': 'a'}),
        ToolCall(id: 'c2', name: 'note', arguments: {}),
      ]),
      _text('查好了'),
    ],
  ),
  _Scenario(
    name: '仅 boundTools 提供工具',
    useBoundTools: true,
    steps: () => [
      _calls('', const [ToolCall(id: 'c1', name: 'lookup', arguments: {})]),
      _text('完成'),
    ],
  ),
  _Scenario(
    name: '文本工具兜底解析与重复跳过',
    steps: () => [
      _text('<execute_tool>{"name":"lookup","arguments":{"q":"x"}}</execute_tool>'),
      _text('<execute_tool>{"name":"lookup","arguments":{"q":"x"}}</execute_tool>'),
    ],
  ),
  _Scenario(
    name: '达到最大轮次',
    maxRounds: 2,
    steps: () => [
      _calls('一', const [ToolCall(id: 'c1', name: 'lookup', arguments: {})]),
      _calls('二', const [ToolCall(id: 'c2', name: 'lookup', arguments: {})]),
    ],
  ),
  _Scenario(
    name: '流式部分输出后失败回退整段',
    stream: true,
    steps: () => [
      _Stream(['半', '截'], StateError('network reset')),
      _calls('', const [ToolCall(id: 'c1', name: 'lookup', arguments: {})]),
      _text('回退后完成'),
    ],
  ),
  _Scenario(
    name: '流式正常带工具',
    stream: true,
    steps: () => [
      _Stream(['想', '一想'], _calls('想一想', const [ToolCall(id: 'c1', name: 'note', arguments: {})])),
      _Stream(['好'], _text('好')),
    ],
  ),
  _Scenario(
    name: '服务端超限恢复一次',
    withContext: true,
    steps: () => [
      _calls('', const [ToolCall(id: 'c1', name: 'lookup', arguments: {})]),
      StateError('context_length_exceeded'),
      _text('压缩后完成'),
    ],
  ),
  _Scenario(
    name: '无压缩器时超限原样抛出',
    steps: () => [StateError('context_length_exceeded')],
  ),
  _Scenario(
    name: '非超限错误原样抛出',
    steps: () => [ArgumentError('bad request')],
  ),
  _Scenario(
    name: 'Claude 续轮内容块',
    modelFullId: 'claude:claude-test',
    steps: () => [
      _calls('先查', const [ToolCall(id: 'toolu_1', name: 'lookup', arguments: {'q': 'c'})], raw: {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '先查'},
          {'type': 'tool_use', 'id': 'toolu_1', 'name': 'lookup', 'input': {'q': 'c'}},
        ],
      }),
      _text('Claude 完成'),
    ],
  ),
  _Scenario(
    name: '快速生图路线：纯生图批次并发执行',
    toolNames: const ['draw_image', 'lookup'],
    fastMode: true,
    steps: () => [
      _calls('画两张', const [
        ToolCall(id: 'd1', name: 'draw_image', arguments: {'tag': 'a'}),
        ToolCall(id: 'd2', name: 'draw_image', arguments: {'tag': 'b'}),
      ]),
      _text('不应再请求'),
    ],
  ),
  _Scenario(
    name: '快速生图路线：混合工具回落串行',
    toolNames: const ['draw_image', 'lookup'],
    fastMode: true,
    steps: () => [
      _calls('画并查', const [
        ToolCall(id: 'd1', name: 'draw_image', arguments: {'tag': 'a'}),
        ToolCall(id: 'l1', name: 'lookup', arguments: {'tag': 'b'}),
      ]),
      _text('混合完成'),
    ],
  ),
  _Scenario(
    name: 'Gemini 思考签名与隐藏思考',
    modelFullId: 'gemini:gemini-test',
    steps: () => [
      SendMessageRichResult(
        text: '',
        toolResults: const [],
        toolCalls: const [
          ToolCall(id: 'g1', name: 'lookup', arguments: {}, thoughtSignature: 'sig-1'),
        ],
        hiddenThoughtParts: const [
          {'thought': true, 'text': '思考'},
        ],
      ),
      _text('Gemini 完成', hidden: const [
        {'thought': true, 'text': '收尾'},
      ]),
    ],
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final legacy = apiRunnerVariants.firstWhere((v) => v.$1 == 'legacy').$2;
  final kernel = apiRunnerVariants.firstWhere((v) => v.$1 == 'kernel').$2;

  for (final sc in _scenarios) {
    test('内核与旧执行器一致：${sc.name}', () async {
      final expected = await _runScenario(legacy, sc);
      final actual = await _runScenario(kernel, sc);
      expect(actual, equals(expected));
    });
  }

  group('run scope lifecycle (B7a)', () {
    Future<List<String>> runWithScope({required bool fail}) async {
      final log = <String>[];
      final plugin = _LoggingPlugin(log);
      final client = _ScriptedClient([
        fail ? ArgumentError('boom') : _text('完成'),
      ]);
      final runner = KernelApiRunner.withAgentClientFactory(
        agentClientFactory: (_) => client,
        scopeFactory: () => KernelScope()..addCloser(() => log.add('dispose')),
      );
      try {
        await runner.executeApiCall(
          config: ApiConfig(
            settings: mapUiModelsToAppSettings({}),
            modelFullId: 'openai:gpt-test',
            providerApiBase: 'https://invalid.test',
            customConfig: const {},
            toolPrefs: const {},
            messages: const [
              {'role': 'user', 'content': '开始'},
            ],
          ),
          sessionId: 'session',
          userText: '开始',
          effectivePlugins: [plugin],
        );
      } catch (_) {
        log.add('error');
      }
      return log;
    }

    test('scope is released once, after result processing', () async {
      expect(await runWithScope(fail: false), ['processResponse', 'dispose']);
    });

    test('scope is released once when the run fails', () async {
      expect(await runWithScope(fail: true), ['dispose', 'error']);
    });
  });

  test('差分基线确实产生了 Trace 与请求记录', () async {
    final snapshot = await _runScenario(legacy, _scenarios[1]);
    expect(snapshot['trace'] as List, isNotEmpty);
    expect(snapshot['requests'] as List, hasLength(2));
  });
}
