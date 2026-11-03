import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ProviderChatRequestOptions;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Send extends ChatSendService {
  _Send(super.ref);
  Future<ApiCallResult> Function(ApiConfig config, String userText)? run;

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
  }) async => ApiConfig(
    settings: _settings,
    modelFullId: 'openai:test',
    providerApiBase: '',
    providerApiKey: null,
    customConfig: const {},
    messages: const [],
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
  }) => run!(config, userText ?? '');
}

final _settings = mapUiModelsToAppSettings({
  'model_configs': {
    'openai:test': {
      'chat_capabilities': ['tools'],
    },
  },
});

/// 「找文件」：第 1 轮读 a.json，第 2 轮读 b.json，第 3 轮作答；
/// 其他输入直接回「收到：<输入>」。runner 只在每次运行的第 1 轮带 userText。
class _Client extends AgentApiClient {
  _Client(this.requests);
  final Map<String, int> requests;
  String _run = '';

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
    if (userText.isNotEmpty) _run = userText;
    final round = requests[_run] = (requests[_run] ?? 0) + 1;
    if (_run != '找文件') {
      return SendMessageRichResult(text: '收到：$_run', toolResults: const []);
    }
    return SendMessageRichResult(
      text: round < 3 ? '' : '找到了',
      toolResults: const [],
      toolCalls: round < 3
          ? [
              ToolCall(
                id: 'call_$round',
                name: 'read',
                arguments: {'path': round == 1 ? 'a.json' : 'b.json'},
              ),
            ]
          : const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SegmentedChatFixture fixture;
  late _Send service;
  late Directory directory;
  late Completer<void> secondEntered;
  late Completer<void> releaseSecond;
  late Map<String, int> requests;
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('queued_input_actions_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  Future<void> setUpFixture(RoleAgentMode mode) async {
    secondEntered = Completer<void>();
    releaseSecond = Completer<void>();
    requests = {};
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      decorate: (conversation) => conversation.copyWith(agentMode: mode),
      extraOverrides: [
        chatSendServiceProvider.overrideWith((ref) {
          service = _Send(ref);
          return service;
        }),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    final runner = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => _Client(requests),
    );
    service.run = (config, userText) => runner.executeApiCall(
      config: config,
      sessionId: fixture.conversation.id,
      userText: userText,
      responseProcessors: const [],
      availableTools: [
        AITool(
          name: 'read',
          description: 'read',
          parameters: const {},
          effect: ToolEffect.readDiagnostic,
          handler: (args) async {
            if (args['path'] == 'b.json') {
              secondEntered.complete();
              await releaseSecond.future;
            }
            return 'content of ${args['path']}';
          },
        ),
      ],
    );
  }

  tearDown(() async {
    if (!releaseSecond.isCompleted) releaseSecond.complete();
    await fixture.dispose();
  });

  ChatActions actions() => fixture.container.read(chatActionsProvider);
  String convId() => fixture.conversation.id;

  Future<List<Message>> stored() => fixture.container
      .read(chatHistoryStoreProvider)
      .loadProjectedMessagesFromRawStore(convId());

  List<String> toolIds(List<Message> messages) => [
    for (final message in messages)
      if (message.role == 'assistant')
        for (final block
            in message.blocks?.whereType<ToolBlock>() ?? const <ToolBlock>[])
          block.toolCallId ?? '',
  ];

  /// 每条消息的角色与可见文字，工具步骤记为 `tools:<id,...>`。
  List<String> transcript(List<Message> messages) => [
    for (final message in messages)
      if (message.role == 'user')
        'user:${message.displayText}'
      else if (toolIds([message]).isNotEmpty)
        'tools:${toolIds([message]).join(',')}'
      else if (message.displayText.trim().isNotEmpty)
        'assistant:${message.displayText.trim()}',
  ];

  Future<void> waitForReply(String text) => fixture.waitUntil(
    () => fixture.timeline.value.any(
      (message) =>
          message.role == 'assistant' && message.displayText.contains(text),
    ),
  );

  group('Agent 模式', () {
    setUp(() => setUpFixture(RoleAgentMode.tool));

    test('插话：等这批工具跑完就停，不再问模型，再把插话当新消息发出', () async {
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      expect(actions().queueWhileRunning('改看 c.json', steer: true), isTrue);
      releaseSecond.complete();
      await send;
      await waitForReply('收到：改看 c.json');

      expect(requests['找文件'], 2, reason: '第 3 次模型请求不该发出');
      final messages = await stored();
      expect(transcript(messages), [
        'user:找文件',
        'tools:call_1',
        'tools:call_2',
        'user:改看 c.json',
        'assistant:收到：改看 c.json',
      ]);
      expect(
        messages.any((m) => m.displayText.contains('Tool call executed')),
        isFalse,
      );
      expect(
        fixture.container.read(conversationQueuedInputsProvider(convId())),
        isEmpty,
      );
    });

    test('排队：等整轮做完才发，交接中途不出现空闲', () async {
      final sending = <bool>[];
      fixture.container.listen<bool>(
        conversationSendingProvider(convId()),
        (_, next) => sending.add(next),
      );
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      expect(actions().queueWhileRunning('再总结一下', steer: false), isTrue);
      expect(
        fixture.container
            .read(conversationQueuedInputsProvider(convId()))
            .map((input) => (input.text, input.steer)),
        [('再总结一下', false)],
      );
      releaseSecond.complete();
      await send;
      await waitForReply('收到：再总结一下');

      expect(requests['找文件'], 3);
      final messages = await stored();
      expect(transcript(messages), [
        'user:找文件',
        'tools:call_1',
        'tools:call_2',
        'assistant:找到了',
        'user:再总结一下',
        'assistant:收到：再总结一下',
      ]);
      await fixture.waitUntil(() => sending.isNotEmpty && !sending.last);
      expect(sending, [true, false]);
    });

    test('撤回插话后这轮照常做完', () async {
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      actions().queueWhileRunning('改看 c.json', steer: true);
      expect(actions().takeQueuedInputs(convId()), ['改看 c.json']);
      releaseSecond.complete();
      await send;
      await waitForReply('找到了');
      expect(requests.keys, ['找文件']);
      expect(requests['找文件'], 3);
    });

    test('连续交接多条也不出现空闲，按顺序各发一次', () async {
      final sending = <bool>[];
      fixture.container.listen<bool>(
        conversationSendingProvider(convId()),
        (_, next) => sending.add(next),
      );
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      for (final text in ['甲', '乙', '丙']) {
        actions().queueWhileRunning(text, steer: false);
      }
      releaseSecond.complete();
      await send;
      await waitForReply('收到：丙');
      await fixture.waitUntil(() => sending.isNotEmpty && !sending.last);

      expect(sending, [true, false]);
      expect(requests, {'找文件': 3, '甲': 1, '乙': 1, '丙': 1});
      expect(
        [
          for (final message in await stored())
            if (message.role == 'user') message.displayText,
        ],
        ['找文件', '甲', '乙', '丙'],
      );
      expect(
        fixture.container.read(returnedQueuedInputsProvider(convId())),
        isEmpty,
      );
    });

    test('插话排在排队前面，各自单独发', () async {
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      actions().queueWhileRunning('最后总结', steer: false);
      actions().queueWhileRunning('先看 c.json', steer: true);
      releaseSecond.complete();
      await send;
      await waitForReply('收到：最后总结');

      final users = [
        for (final message in await stored())
          if (message.role == 'user') message.displayText,
      ];
      expect(users, ['找文件', '先看 c.json', '最后总结']);
    });

    test('停止时排队的话退回输入框，不再发出', () async {
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      actions().queueWhileRunning('插一句', steer: true);
      actions().queueWhileRunning('排一句', steer: false);
      await actions().interruptCurrentGeneration(convId: convId());
      releaseSecond.complete();
      await send;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        fixture.container.read(conversationQueuedInputsProvider(convId())),
        isEmpty,
      );
      expect(
        fixture.container.read(returnedQueuedInputsProvider(convId())),
        ['插一句', '排一句'],
      );
      expect(requests.keys, ['找文件']);
    });

    test('没在运行时不排队，交给正常发送', () async {
      expect(actions().queueWhileRunning('你好', steer: true), isFalse);
    });
  });

  group('聊天模式', () {
    setUp(() => setUpFixture(RoleAgentMode.chat));

    test('运行中也不接受插话或排队', () async {
      final send = actions().send('找文件');
      await secondEntered.future.timeout(const Duration(seconds: 10));
      expect(actions().queueWhileRunning('插一句', steer: true), isFalse);
      releaseSecond.complete();
      await send;
    });
  });
}
