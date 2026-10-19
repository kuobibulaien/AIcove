// Real-model check for ADR0088 W2 (opt-in): the chat model delegates a
// lookup, the errand agent runs it with a tool and writes a receipt, and the
// chat model relays the receipt in persona. DeepSeek Flash; skipped unless
// DEEPSEEK_API_KEY is set. The key is read from the environment only.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_request_context.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_service.dart';
import 'package:aicove_flutter/src/features/task_agent/data/agent_task_store.dart';
import 'package:aicove_flutter/src/features/task_agent/data/task_process_record.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

final String? _apiKey = Platform.environment['DEEPSEEK_API_KEY'];
final _settings = mapUiModelsToAppSettings({});
final _runner = createApiRunner(useKernel: true);

ApiConfig _config(List<Map<String, dynamic>> messages, List<AITool> tools) =>
    ApiConfig(
      settings: _settings,
      modelFullId: 'openai:deepseek-flash',
      providerApiBase: 'https://api.deepseek.com',
      providerApiKey: _apiKey,
      customConfig: const {},
      modelTemperature: 0.3,
      messages: messages,
      tools: tools.isEmpty ? null : [for (final t in tools) t.toOpenAISchema()],
      boundTools: tools,
    );

const _persona =
    '你是「小满」，用户的朋友，说话轻松俏皮，句子短，爱用「呀」「啦」。';

class _Port implements DelegateTaskPort {
  _Port(this.service);
  final TaskAgentService service;

  @override
  Future<Map<String, Object?>> start({
    required String conversationId,
    required String instruction,
    required String? callKey,
  }) async {
    final task = await service.start(
      conversationId: conversationId,
      instruction: instruction,
      requestKey: 'mac|$callKey',
    );
    return {'task_id': task.id, 'status': 'accepted'};
  }

  @override
  Future<Map<String, Object?>> reply({
    required String conversationId,
    required String taskId,
    required String answer,
    required String? callKey,
  }) async => {'error': 'unused'};

  @override
  Future<Map<String, Object?>> cancel({
    required String conversationId,
    required String taskId,
    required String? callKey,
  }) async => {'error': 'unused'};
}

void main() {
  final skip = _apiKey == null ? '未设置 DEEPSEEK_API_KEY' : false;

  test('查一件事 → 回执 → 人设转告', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c1',
            title: '小满',
            displayName: '小满',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
    final dir = await Directory.systemTemp.createTemp('task_real');
    addTearDown(() => dir.delete(recursive: true));
    final weatherCalls = <String>[];
    final weather = AITool(
      name: 'get_weather',
      description: '查询城市某天的天气预报，返回 JSON。',
      parameters: const {},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
          'day': {'type': 'string', 'description': '今天／明天'},
        },
        'required': ['city'],
      },
      effect: ToolEffect.external,
      handler: (args) async {
        weatherCalls.add(jsonEncode(args));
        return jsonEncode({
          'city': args['city'],
          'day': args['day'] ?? '明天',
          'weather': '中雨转小雨',
          'temp': '15～19°C',
          'rain_probability': '85%',
        });
      },
    );
    final receipts = <RecordedReceipt>[];
    final service = TaskAgentService(
      store: AgentTaskStore(database),
      process: TaskProcessRecord(dir),
      runner: TaskAgentRunner(
        loadSettings: () async => _settings,
        requestConfig: ({required settings, required modelRef}) async =>
            BackgroundAgentRequestConfig(
              modelFullId: 'openai:deepseek-flash',
              providerApiBase: 'https://api.deepseek.com',
              providerApiKey: _apiKey,
              customConfig: const <String, dynamic>{},
              modelTemperature: 0,
              modelTopP: null,
              modelContextMessageLimit: null,
            ),
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required maxRounds,
              required cancellation,
            }) => _runner.executeApiCall(
              config: config,
              sessionId: sessionId,
              userText: null,
              responseProcessors: const [],
              availableTools: tools,
              maxRounds: maxRounds,
              cancellation: cancellation,
            ),
      ),
      capabilities: (_, _, _) async =>
          TaskAgentCapabilities(tools: [weather]),
      writeReceipt: (receipt) async => receipts.add(receipt),
      relay: (_, _) async => true,
      findReceipt: (_) async => null,
      ownsConversation: (_) async => true,
      deviceId: () async => 'mac',
    );

    // 1. The chat turn: the model may only delegate.
    final scope = DelegateTaskRequestScope(_Port(service), active: true);
    final system = '$_persona\n\n${await scope.prompt(_noContext)}';
    const ask = '小满，帮我查一下杭州明天会不会下雨呀，我在纠结要不要带伞';
    final chat = await _runner.executeApiCall(
      config: _config([
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': ask},
      ], scope.tools()),
      sessionId: 'c1',
      userText: ask,
      turnId: 'run1',
      responseProcessors: const [],
      availableTools: scope.tools(),
    );
    final chatReply = chat.replyText.trim();
    // ignore: avoid_print
    print('聊天回复：$chatReply');
    expect(chat.toolCalls.map((c) => c.name), contains(delegateTaskToolName));
    expect(chatReply, isNot(contains('85%')), reason: '回执前不能编造结果');

    // 2. The errand agent runs in the background and writes a receipt.
    await service.idle();
    final task = (await service.store.recent()).single;
    expect(task.requestKey, startsWith('mac|c1|run1|'));
    expect(task.status, AgentTaskStatus.done);
    expect(weatherCalls, isNotEmpty);
    final receipt = receipts.single.block;
    // ignore: avoid_print
    print('任务说明：${task.instruction}\n回执：${receipt.content}');
    // ignore: avoid_print
    print('过程：${await TaskProcessRecord(dir).log(task.id)}');
    expect(receipt.receiptStatus, TaskReceiptStatus.done);
    expect(receipt.summary, contains('雨'));
    expect(receipt.sideEffectUncertain, isFalse);

    // 3. The relay: the persona tells the user, from the receipt only.
    final relay = await _runner.executeApiCall(
      config: _config([
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': ask},
        {'role': 'assistant', 'content': chatReply},
        {'role': 'user', 'content': receipt.content},
        {
          'role': 'user',
          'content':
              '<system-reminder>你之前交给后台去办的事有结果了（见上一条杂活回执）。'
              '用你的口吻把结果告诉用户，只说回执里有的内容，不要编造，'
              '不要提「回执」这个词。</system-reminder>',
        },
      ], const []),
      sessionId: 'c1',
      userText: null,
      responseProcessors: const [],
      availableTools: const [],
    );
    final relayText = relay.replyText.trim();
    // ignore: avoid_print
    print('人设转告：$relayText');
    expect(relayText, contains('雨'));
    expect(relayText, isNot(contains('回执')));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}

const _noContext = PluginRequestContextStub();

class PluginRequestContextStub extends PluginRequestContext {
  const PluginRequestContextStub()
    : super(userMessage: '', supportsToolCalling: true);
}
