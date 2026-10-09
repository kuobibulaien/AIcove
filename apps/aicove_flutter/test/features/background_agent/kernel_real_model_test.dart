// Real-model comparison for ADR0064 batch 1b (opt-in).
//
// Runs a background memory agent (with a tool) and a summary agent (no tools)
// through BackgroundAgentService on the legacy and the kernel runner against
// DeepSeek Flash. Skipped unless DEEPSEEK_API_KEY is set; the key is read
// from the environment only and never written anywhere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_agent_definition.dart';
import 'package:aicove_flutter/src/features/background_agent/domain/background_context_spec.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_manager.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];

Future<(List<String>, List<String>, String)> _runAgent({
  required bool useKernel,
  required bool withTool,
}) async {
  final executions = <String>[];
  final lookup = AITool(
    name: 'memory_lookup',
    description: '查询用户的长期记忆，返回 JSON。',
    parameters: const {},
    handler: (_) async {
      executions.add('memory_lookup');
      return jsonEncode({'success': true, 'memory': '用户偏好无糖美式，周末常去图书馆'});
    },
  );
  final runner = createApiRunner(useKernel: useKernel);
  final service = BackgroundAgentService(
    loadRecentMessages: (_, __) async => [
      Message.text(
        id: 'm1',
        role: 'user',
        content: '我周末想找个安静的地方看书，顺便喝杯咖啡。',
        createdAt: DateTime(2026, 10, 7, 10),
      ),
    ],
    loadSettings: () async => mapUiModelsToAppSettings({}),
    readPluginManager: () => PluginManager(),
    requestConfigResolver: ({
      required AppSettings settings,
      required String? modelRef,
    }) async =>
        BackgroundAgentRequestConfig(
          modelFullId: 'openai:deepseek-flash',
          providerApiBase: 'https://api.deepseek.com',
          providerApiKey: _apiKey,
          customConfig: const <String, dynamic>{},
          modelTemperature: 0,
          modelTopP: null,
          modelContextMessageLimit: null,
        ),
    executor: ({
      required ApiConfig config,
      required List<AITool> availableTools,
      required String sessionId,
      required int maxRounds,
    }) =>
        runner.executeApiCall(
          config: config,
          sessionId: sessionId,
          userText: null,
          effectivePlugins: const [],
          availableTools: availableTools,
          maxRounds: maxRounds,
          traceContext: config.traceContext,
        ),
  );
  final result = await service.run(
    definition: BackgroundAgentDefinition(
      id: withTool ? 'memory_agent' : 'summary_agent',
      name: withTool ? '记忆整理' : '摘要',
      objectivePrompt: withTool
          ? '先调用 memory_lookup 工具查询用户偏好，再用一句话给出建议。'
          : '用一句话概括用户的需求，不要调用工具。',
      contextSpec: const BackgroundContextSpec(lastMessages: 1),
      allowedToolNames: withTool ? const ['memory_lookup'] : const [],
      maxRounds: withTool ? 3 : 1,
    ),
    conversationId: 'real_model_conv',
    additionalTools: withTool ? [lookup] : const [],
  );
  final reply = result.processedText.trim().isNotEmpty
      ? result.processedText
      : result.replyText;
  return ([for (final c in result.toolCalls) c.name], executions, reply);
}

Future<(List<String>, int, String)> _runStreamingChat({
  required bool useKernel,
}) async {
  final executions = <String>[];
  final weather = AITool(
    name: 'get_weather',
    description: '查询指定城市今天的天气。',
    parameters: const {},
    handler: (_) async {
      executions.add('get_weather');
      return jsonEncode({'city': '杭州', 'weather': '小雨', 'temp': '18°C'});
    },
  );
  final deltas = <String>[];
  final result = await createApiRunner(useKernel: useKernel).executeApiCall(
    config: ApiConfig(
      settings: mapUiModelsToAppSettings({}),
      modelFullId: 'openai:deepseek-flash',
      providerApiBase: 'https://api.deepseek.com',
      providerApiKey: _apiKey,
      customConfig: const {},
      toolPrefs: const {},
      modelTemperature: 0,
      messages: const [
        {'role': 'system', 'content': '你是简洁的助手。需要天气时先调用 get_weather。'},
        {'role': 'user', 'content': '杭州今天天气怎么样？一句话回答。'},
      ],
      tools: [weather.toOpenAISchema()],
      boundTools: [weather],
    ),
    sessionId: 'real_chat',
    userText: '杭州今天天气怎么样？一句话回答。',
    effectivePlugins: const [],
    enableStreaming: true,
    onStreamTextDelta: deltas.add,
  );
  final reply = result.processedText.trim().isNotEmpty
      ? result.processedText
      : result.replyText;
  return (executions, deltas.length, reply);
}

void main() {
  final skip = _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false;
  const timeout = Timeout(Duration(minutes: 3));

  test('真实模型：后台记忆 Agent 新旧执行器工具轨迹一致', () async {
    final legacy = await _runAgent(useKernel: false, withTool: true);
    final kernel = await _runAgent(useKernel: true, withTool: true);
    // ignore: avoid_print
    print('REAL legacy=$legacy\nREAL kernel=$kernel');
    expect(legacy.$1, contains('memory_lookup'));
    expect(kernel.$1, legacy.$1);
    expect(kernel.$2, legacy.$2);
    expect(kernel.$3.trim(), isNotEmpty);
  }, skip: skip, timeout: timeout);

  test('真实模型：后台摘要 Agent 新旧执行器均不调工具且有回复', () async {
    final legacy = await _runAgent(useKernel: false, withTool: false);
    final kernel = await _runAgent(useKernel: true, withTool: false);
    // ignore: avoid_print
    print('REAL legacy=$legacy\nREAL kernel=$kernel');
    expect(legacy.$1, isEmpty);
    expect(kernel.$1, isEmpty);
    expect(kernel.$3.trim(), isNotEmpty);
  }, skip: skip, timeout: timeout);

  test('真实模型：前台流式聊天带工具，新旧执行器轨迹一致', () async {
    final legacy = await _runStreamingChat(useKernel: false);
    final kernel = await _runStreamingChat(useKernel: true);
    // ignore: avoid_print
    print('REAL legacy=$legacy\nREAL kernel=$kernel');
    expect(legacy.$1, ['get_weather']);
    expect(kernel.$1, legacy.$1);
    expect(kernel.$2, greaterThan(0));
    expect(kernel.$3.trim(), isNotEmpty);
  }, skip: skip, timeout: timeout);
}
