import 'dart:async';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart'
    show AgentToolAuthorization;
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect, KernelCancelledException;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult, ProviderChatRequestOptions;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/chat_layer_providers.dart';
import 'package:aicove_flutter/src/features/chat/infrastructure/chat_port_adapters.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
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
  Future<ApiCallResult> Function(ApiConfig config)? run;
  void Function(String)? emit;

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
    toolPolicy: const AgentToolPolicy(
      authorization: AgentToolAuthorization.allowAll,
    ),
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
  }) {
    emit = onStreamTextDelta;
    return run!(config);
  }
}

class _ProgressHistory extends ChatHistoryStoreAdapter {
  _ProgressHistory(super.store);
  bool countWrites = false;
  bool failPartial = false;
  bool failAfterFormal = false;
  Completer<void>? releaseFormal;
  final formalCommitted = Completer<void>();
  final snapshots = <Message>[];
  final firstEntered = Completer<void>();
  Completer<void>? releaseFirst;

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
  }) async {
    if (failPartial && updateSummary && rawMessage.rawPayload?['runStatus'] == 'cancelled') {
      throw StateError('partial storage failed');
    }
    if (countWrites && !updateSummary) {
      snapshots.add(rawMessage);
      if (snapshots.length == 1) {
        firstEntered.complete();
        await releaseFirst?.future;
      }
    }
    await super.appendAssistantRawMessage(
      conversationId: conversationId,
      userMessageId: userMessageId,
      rawMessage: rawMessage,
      projectedMessages: projectedMessages,
      lastMessagePreview: lastMessagePreview,
      updateShortWindow: updateShortWindow,
      updateSummary: updateSummary,
      shouldCommit: shouldCommit,
    );
    if (updateSummary && failAfterFormal) throw StateError('formal cache refresh failed');
    if (updateSummary && releaseFormal != null) {
      if (!formalCommitted.isCompleted) formalCommitted.complete();
      await releaseFormal!.future;
    }
  }
}

final _twoModels = segmentedProbeSettings.copyWith(
  defaultModelName: 'openai:a',
  defaultChatModels: const ['openai:a', 'openai:b'],
  modelList: const ['openai:a', 'openai:b'],
  allKnownModels: const ['openai:a', 'openai:b'],
  modelProviderMap: const {'openai:a': 'openai', 'openai:b': 'openai'},
);

final _settings = mapUiModelsToAppSettings({
  'model_configs': {
    'openai:test': {
      'chat_capabilities': ['tools'],
    },
  },
});

/// Round 1 reads a.json, round 2 reads b.json, round 3 answers.
class _Client extends AgentApiClient {
  int requests = 0;
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
    final round = ++requests;
    return SendMessageRichResult(
      text: round < 3 ? '第$round轮读文件' : '找到了',
      reasoning: '第$round轮思考',
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
  late _ProgressHistory progressHistory;
  late Directory directory;
  late Completer<void> secondEntered;
  late Completer<void> releaseSecond;
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('tool_progress_actions_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    secondEntered = Completer<void>();
    releaseSecond = Completer<void>();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      decorate: (c) => c.copyWith(agentMode: RoleAgentMode.tool),
      extraOverrides: [
        chatHistoryPortProvider.overrideWith((ref) {
          return progressHistory = _ProgressHistory(ref.read(chatHistoryStoreProvider));
        }),
        chatSendServiceProvider.overrideWith((ref) {
          service = _Send(ref);
          return service;
        }),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    fixture.container.read(chatHistoryPortProvider);
    final runner = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => _Client(),
    );
    service.run = (config) => runner.executeApiCall(
      config: config,
      sessionId: fixture.conversation.id,
      userText: '找文件',
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
  });
  tearDown(() async {
    if (!releaseSecond.isCompleted) releaseSecond.complete();
    await fixture.dispose();
  });

  ChatActions actions() => fixture.container.read(chatActionsProvider);

  List<ToolBlock> toolBlocks(List<Message> messages) => [
    for (final message in messages)
      if (message.role == 'assistant')
        ...?message.blocks?.whereType<ToolBlock>(),
  ];

  String visibleText(List<Message> messages) => [
    for (final message in messages.where((m) => m.role == 'assistant'))
      if (message.blocks == null) message.content
      else ...message.blocks!.whereType<TextBlock>().map((b) => b.content),
  ].join();

  Future<List<Message>> stored() => fixture.container
      .read(chatHistoryStoreProvider)
      .loadProjectedMessagesFromRawStore(fixture.conversation.id);

  Future<List<Map<String, dynamic>>> replay() async {
    final tail = Message.text(id: 'continue', role: 'user', content: '继续');
    final history = await service.prepareHistoryFromStore(
      conv: fixture.conversation,
      userMsg: tail,
    );
    return ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    ).buildRequestMessages(history, settings: _settings);
  }

  void expectInterrupted(List<Map<String, dynamic>> request) {
    expect(request.map((m) => m['role']), [
      'user',
      'assistant',
      'tool',
      'assistant',
      'tool',
      'assistant',
      'user',
    ]);
    expect(request[1]['content'], '第1轮读文件');
    expect(request[3]['content'], '第2轮读文件');
    expect((request[1]['tool_calls'] as List).single['id'], 'call_1');
    expect((request[3]['tool_calls'] as List).single['id'], 'call_2');
    expect(request[2]['content'], contains('content of a.json'));
    expect(request[4]['content'], contains('已中断，未拿到结果'));
    expect(request[5]['content'], contains('中断'));
    expect(request.last['content'], '继续');
  }

  for (final failPartial in [false, true]) {
    test('停止仅保留可见话术一次，半截保存失败仍保全工具: $failPartial', () async {
      progressHistory.failPartial = failPartial;
      final emitted = Completer<void>();
      const call = ToolCall(id: 'settled', name: 'read', arguments: {});
      const result = ToolResult(toolCallId: 'settled', name: 'read', result: 'kept');
      service.run = (config) async {
        await config.onToolRounds!([
          const ReplyRound(replyText: '已经显示。', processedText: '已经显示。',
            rawText: '原始工具话术', toolCallIds: ['settled']),
        ], [call]);
        await config.onToolCompleted!(call, result);
        service.emit!('已经显示。');
        emitted.complete();
        await config.cancellation!.whenCancelled;
        throw const KernelCancelledException();
      };
      final send = actions().send('找文件');
      await emitted.future;
      await fixture.waitUntil(() => fixture.timeline.value.any((m) =>
          m.role == 'assistant' && m.displayText.contains('已经显示。')));
      service.emit!('尚未展示的缓冲内容。');
      await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
      await send;
      final messages = await stored();
      final text = visibleText(messages);
      expect(text, isNot(contains('尚未展示')));
      expect('已经显示'.allMatches(text), hasLength(failPartial ? 0 : 1));
      expect(toolBlocks(messages).map((b) => b.toolCallId), ['settled']);
      final request = await replay();
      expect(request.where((m) => m['role'] == 'tool').single['content'], contains('kept'));
      expect(request.where((m) => m['role'] == 'assistant').first['content'], '原始工具话术');
      expect(fixture.container.read(conversationSendingProvider(fixture.conversation.id)), isFalse);
    });
  }

  test('正式 raw 已提交但交付未返回时停止，不再新增第二份半截 raw', () async {
    progressHistory.releaseFormal = Completer<void>();
    const call = ToolCall(id: 'settled', name: 'read', arguments: {});
    const result = ToolResult(toolCallId: 'settled', name: 'read', result: 'kept');
    service.run = (config) async {
      await config.onToolCompleted!(call, result);
      service.emit!('正式回复。');
      return const ApiCallResult(replyText: '正式回复。', processedText: '正式回复。',
        pluginEvents: [], toolResults: [], toolCalls: [call], rawToolResults: [result]);
    };
    final send = actions().send('找文件');
    try {
      await progressHistory.formalCommitted.future.timeout(const Duration(seconds: 5));
      await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
      final raw = await fixture.container.read(chatHistoryStoreProvider)
          .loadAllRawMessages(fixture.conversation.id);
      expect(raw.where((m) => m.role == 'assistant'), hasLength(1));
      expect(toolBlocks(await stored()).map((b) => b.toolCallId), ['settled']);
    } finally {
      progressHistory.releaseFormal!.complete();
      await send;
    }
  });

  test('正式 raw 提交后的交付异常即时恢复投影，不补写重复半截', () async {
    progressHistory.failAfterFormal = true;
    service.run = (config) async {
      service.emit!('已提交的回复。');
      return const ApiCallResult(replyText: '已提交的回复。', processedText: '已提交的回复。',
        pluginEvents: [], toolResults: []);
    };
    await actions().send('保留回复');
    final raw = await fixture.container.read(chatHistoryStoreProvider)
        .loadAllRawMessages(fixture.conversation.id);
    expect(raw.where((m) => m.role == 'assistant'), hasLength(1));
    await fixture.waitUntil(() => fixture.timeline.value.any((m) =>
        m.role == 'assistant' && m.displayText.contains('已提交的回复')));
    expect(fixture.container.read(conversationSendingProvider(fixture.conversation.id)), isFalse);
  });

  test('正常多轮 raw 重新准备上下文时逐轮交替，不使用投影', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    releaseSecond.complete();
    await send;
    final request = await replay();
    expect(request.map((m) => m['role']), [
      'user',
      'assistant',
      'tool',
      'assistant',
      'tool',
      'assistant',
      'user',
    ]);
    expect(request[1]['content'], '第1轮读文件');
    expect(request[3]['content'], '第2轮读文件');
    expect(request[5]['content'], '找到了');
  });

  test('停止后继续：完整轮次与在途调用均可从真实 raw 回放', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
    releaseSecond.complete();
    await send;
    expectInterrupted(await replay());
  });

  test('第一个工具尚未返回也先落盘，停止后补齐它的中断结果', () async {
    final runner = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => _Client(),
    );
    service.run = (config) => runner.executeApiCall(
      config: config, sessionId: fixture.conversation.id, userText: '找文件',
      responseProcessors: const [], availableTools: [
        AITool(name: 'read', description: 'read', parameters: const {},
          effect: ToolEffect.readDiagnostic, handler: (args) async {
            secondEntered.complete();
            await releaseSecond.future;
            return 'late result';
          }),
      ],
    );
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
    releaseSecond.complete();
    await send;
    final request = await replay();
    expect(request.map((m) => m['role']), ['user', 'assistant', 'tool', 'assistant', 'user']);
    expect((request[1]['tool_calls'] as List).single['id'], 'call_1');
    expect(request[1]['content'], '第1轮读文件');
    expect(request[2]['content'], '已中断，未拿到结果');
    expect(request[3]['content'], contains('中断'));
  });

  test('模拟进程被杀：只读运行中的落盘 raw 也能补全中断', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    final raws = await fixture.container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(fixture.conversation.id);
    final raw = raws.singleWhere((m) => m.role == 'assistant');
    expect(raw.rawPayload?['stopReason'], 'inProgress');
    expect((raw.rawPayload?['replyRounds'] as List).length, 2);
    expect((raw.rawPayload?['replyRounds'] as List).first['reasoning'], '第1轮思考');
    // No cancellation/finalization callback: reload only what reached storage.
    expectInterrupted(await replay());
    releaseSecond.complete();
    await send;
  });

  test('请求失败后继续：已完成轮次的文字不丢失', () async {
    service.run = (config) async {
      await config.onToolCompleted!(
        const ToolCall(id: 'done', name: 'read', arguments: {}),
        const ToolResult(toolCallId: 'done', name: 'read', result: 'ok'),
      );
      throw StateError('404');
    };
    await actions().send('找文件');
    final request = await replay();
    expect(request.last['content'], '继续');
    expect(request[request.length - 2]['content'], contains('中断'));
  });

  test('插话让出后正式 raw 接手，不重复步骤也不添加中断提示', () async {
    final firstRun = service.run!;
    var runs = 0;
    service.run = (config) => ++runs == 1 ? firstRun(config) : Future.value(
      const ApiCallResult(replyText: '收到插话', processedText: '收到插话',
        pluginEvents: [], toolResults: []),
    );
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    expect(actions().queueWhileRunning('换个任务', steer: true), isTrue);
    releaseSecond.complete();
    await send;
    await fixture.waitUntil(() => fixture.timeline.value.any(
      (m) => m.displayText.contains('收到插话')));
    final request = await replay();
    expect(request.where((m) => m['role'] == 'tool').map((m) => m['tool_call_id']),
        ['call_1', 'call_2']);
    expect(request.map((m) => m['content']).join(), isNot(contains('请求已中断')));
    final raws = await fixture.container.read(chatHistoryStoreProvider)
        .loadAllRawMessages(fixture.conversation.id);
    expect(raws.where((m) => m.rawPayload?['stopReason'] == 'inProgress'), isEmpty);
  });

  test('第一步工具完成后，卡片在回复结束前就已落库并出现在聊天里', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    await fixture.waitUntil(
      () => toolBlocks(fixture.timeline.value).isNotEmpty,
    );
    expect(toolBlocks(await stored()).map((block) => block.toolCallId), [
      'call_1',
    ]);
    releaseSecond.complete();
    await send;
  });

  test('中途取消保留已完成的步骤并标为已中断', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    await fixture.waitUntil(
      () => toolBlocks(fixture.timeline.value).isNotEmpty,
    );
    await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
    releaseSecond.complete();
    await send;
    final messages = await stored();
    expect(toolBlocks(messages).map((block) => block.toolCallId), ['call_1']);
    expect(messages.last.rawPayload?['runStatus'], 'cancelled');
    expect(visibleText(messages), isNot(contains('第2轮读文件')),
        reason: '工具轮次原文可回放，但没有 reveal 的话术不能重建成已说出的文字');
    expectInterrupted(await replay());
  });

  test('正常结束由正式回复接替，工具卡片不重复', () async {
    final send = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    releaseSecond.complete();
    await send;
    final messages = await stored();
    expect(toolBlocks(messages).map((block) => block.toolCallId), [
      'call_1',
      'call_2',
    ]);
    expect(
      toolBlocks(fixture.timeline.value).map((block) => block.toolCallId),
      ['call_1', 'call_2'],
    );
    expect(messages.last.displayText, contains('找到了'));
  });

  test('失败切换模型后，前一个模型做过的步骤留在过程消息里', () async {
    await fixture.dispose();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      decorate: (c) => c.copyWith(agentMode: RoleAgentMode.tool),
      settings: _twoModels,
      extraOverrides: [
        chatSendServiceProvider.overrideWith((ref) {
          service = _Send(ref);
          return service;
        }),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    var attempts = 0;
    service.run = (config) async {
      if (++attempts == 1) {
        await config.onToolRounds!(
          const [ReplyRound(replyText: '先写文件', processedText: '先写文件', toolCallIds: ['call_a'])],
          const [ToolCall(id: 'call_a', name: 'write', arguments: {})],
        );
        await config.onToolCompleted!(
          const ToolCall(id: 'call_a', name: 'write', arguments: {}),
          ToolResult(toolCallId: 'call_a', name: 'write', result: 'ok'),
        );
        throw StateError('model a failed');
      }
      return const ApiCallResult(
        replyText: '换个模型答完了',
        processedText: '换个模型答完了',
        pluginEvents: [],
        toolResults: [],
      );
    };
    final controller = fixture.container.read(modelFailoverPromptProvider.notifier);
    final detach = controller.attachPresenter(fixture.conversation.id);
    addTearDown(detach);
    final send = actions().send('写文件');
    await fixture.waitUntil(
      () => fixture.container.read(modelFailoverPromptForProvider(fixture.conversation.id)) != null,
    );
    final prompt = fixture.container.read(modelFailoverPromptForProvider(fixture.conversation.id))!;
    controller.resolve(fixture.conversation.id, prompt.requestId, ModelFailoverDecision.tryNext);
    await send;
    expect(attempts, 2);
    final messages = await stored();
    expect(toolBlocks(messages).map((block) => block.toolCallId), ['call_a']);
    expect(messages.last.displayText, contains('换个模型答完了'));
    final request = await replay();
    expect(request[1]['content'], '先写文件');
    expect(request.where((m) => m['role'] == 'tool').map((m) => m['tool_call_id']), ['call_a']);
    expect(request.map((m) => m['content']).join(), contains('请求已中断'));
  });

  test('重试状态按会话显示，收到文字和生成结束后清除', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    late ApiConfig captured;
    service.run = (config) async {
      captured = config;
      config.onModelRetry!(1, 3, Duration.zero);
      entered.complete();
      await finish.future;
      return const ApiCallResult(
        replyText: '完成', processedText: '完成', pluginEvents: [], toolResults: [],
      );
    };
    final send = actions().send('测试重试');
    await entered.future;
    final status = fixture.container.read(conversationRetryStatusProvider(fixture.conversation.id));
    expect(status?.attempt, 1);
    expect(status?.maxAttempts, 3);
    expect(fixture.container.read(conversationRetryStatusProvider('other')), isNull);
    service.emit!('文字');
    expect(fixture.container.read(conversationRetryStatusProvider(fixture.conversation.id)), isNull);
    captured.onModelRetry!(1, 1, Duration.zero);
    finish.complete();
    await send;
    expect(fixture.container.read(conversationRetryStatusProvider(fixture.conversation.id)), isNull);
    captured.onModelRetry!(2, 3, Duration.zero);
    expect(fixture.container.read(conversationRetryStatusProvider(fixture.conversation.id)), isNull);
  });

  test('重新生成：新过程落库就撤掉旧回复，只做完工具便取消也不留两份', () async {
    final first = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    releaseSecond.complete();
    await first;
    final oldReply = (await stored()).lastWhere(
      (message) => message.displayText.contains('找到了'),
    );

    secondEntered = Completer<void>();
    releaseSecond = Completer<void>();
    final regenerate = actions().regenerate(oldReply.id);
    await secondEntered.future.timeout(const Duration(seconds: 10));
    await fixture.waitUntil(
      () => toolBlocks(fixture.timeline.value).length == 1,
    );
    await actions().interruptCurrentGeneration(convId: fixture.conversation.id);
    releaseSecond.complete();
    await regenerate;
    final messages = await stored();
    expect(
      messages.where((message) => message.displayText.contains('找到了')),
      isEmpty,
    );
    expect(toolBlocks(messages).map((block) => block.toolCallId), ['call_1']);
  });

  test('重生成工具先撤旧后，无正文 delta 也能显示生成中', () async {
    final first = actions().send('找文件');
    await secondEntered.future.timeout(const Duration(seconds: 10));
    releaseSecond.complete();
    await first;
    final oldReply = (await stored()).lastWhere(
      (message) => message.displayText.contains('找到了'),
    );

    secondEntered = Completer<void>();
    releaseSecond = Completer<void>();
    final beforeToolWrite = Completer<void>();
    final allowToolWrite = Completer<void>();
    final run = service.run!;
    service.run = (config) => run(config.copyWith(
      onToolRounds: (rounds, calls) async {
        if (!beforeToolWrite.isCompleted) {
          beforeToolWrite.complete();
          await allowToolWrite.future;
        }
        await config.onToolRounds!(rounds, calls);
      },
    ));
    bool hasPlaceholder() => fixture.timeline.value.any(
          (m) => m.role == 'assistant' && m.displayText == '生成中...',
        ) || fixture.container
            .read(activeStreamProjectionsProvider)[fixture.conversation.id]
            ?.phase == ActiveStreamPhase.thinking;

    final elapsed = Stopwatch()..start();
    final regenerate = actions().regenerate(oldReply.id);
    try {
      await beforeToolWrite.future.timeout(const Duration(seconds: 10));
      expect(visibleText(fixture.timeline.value), contains('找到了'));
      expect(hasPlaceholder(), isFalse);

      allowToolWrite.complete();
      await secondEntered.future.timeout(const Duration(seconds: 10));
      await fixture.waitUntil(() => toolBlocks(fixture.timeline.value).length == 1);
      expect(visibleText(fixture.timeline.value), isNot(contains('找到了')));
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 450)),
          reason: '工具须在生成中计时器到期前撤旧');
      // 已知限制：计时器到期后才撤旧，标记本身不会主动触发刷新。
      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(hasPlaceholder(), isTrue,
          reason: '工具撤旧后，即使尚无正文 delta，计时器到期也应显示生成中');
    } finally {
      if (!allowToolWrite.isCompleted) allowToolWrite.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
      await regenerate;
    }
  });

  test('模型失败结束时，排队中的步骤也全部落库并标为失败', () async {
    service.run = (config) async {
      for (final id in ['call_x', 'call_y']) {
        unawaited(
          config.onToolCompleted!(
            ToolCall(id: id, name: 'read', arguments: const {}),
            ToolResult(toolCallId: id, name: 'read', result: 'ok'),
          ),
        );
      }
      throw StateError('model failed');
    };
    await actions().send('找文件');
    final raws = await fixture.container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(fixture.conversation.id);
    final progress = raws.singleWhere((m) => m.role == 'assistant');
    expect(progress.blocks?.whereType<ToolBlock>().map((b) => b.toolCallId), [
      'call_x',
      'call_y',
    ]);
    expect(progress.rawPayload?['runStatus'], 'failed');
  });
  for (final whileWriting in [false, true]) {
    test('工具完成合并待执行快照，写入期间的新结果不丢失: $whileWriting', () async {
      fixture.container.read(chatHistoryPortProvider);
      progressHistory.countWrites = true;
      if (whileWriting) progressHistory.releaseFirst = Completer<void>();
      service.run = (config) async {
        void complete(String id) => unawaited(config.onToolCompleted!(
          ToolCall(id: id, name: 'read', arguments: const {}),
          ToolResult(toolCallId: id, name: 'read', result: 'ok'),
        ));
        complete('first');
        if (whileWriting) await progressHistory.firstEntered.future;
        complete('second');
        complete('third');
        await progressHistory.firstEntered.future;
        secondEntered.complete();
        await releaseSecond.future;
        throw StateError('model failed');
      };
      final send = actions().send('并发工具');
      try {
        await secondEntered.future.timeout(const Duration(seconds: 10));
        if (whileWriting) progressHistory.releaseFirst!.complete();
        final expectedWrites = whileWriting ? 2 : 1;
        await fixture.waitUntil(() => progressHistory.snapshots.length >= expectedWrites);
        // Let already-queued writes drain; the model remains behind the barrier.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(progressHistory.snapshots, hasLength(expectedWrites));
        expect(progressHistory.snapshots.last.rawPayload?['rawToolResults'], hasLength(3));
        if (whileWriting) {
          expect(progressHistory.snapshots.first.rawPayload?['rawToolResults'], hasLength(1));
        }
      } finally {
        final barrier = progressHistory.releaseFirst;
        if (barrier != null && !barrier.isCompleted) barrier.complete();
        if (!releaseSecond.isCompleted) releaseSecond.complete();
        await send;
      }
      final raws = await fixture.container.read(chatHistoryStoreProvider)
          .loadAllRawMessages(fixture.conversation.id);
      expect(raws.singleWhere((m) => m.role == 'assistant').rawPayload?['rawToolResults'], hasLength(3));
    });
  }

  test('多模型下上下文压缩异常直接上抛，不弹切换模型确认框也不重试下一个模型', () async {
    await fixture.dispose();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      decorate: (c) => c.copyWith(agentMode: RoleAgentMode.tool),
      settings: _twoModels,
      extraOverrides: [
        chatSendServiceProvider.overrideWith((ref) {
          service = _Send(ref);
          return service;
        }),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    var attempts = 0;
    service.run = (_) async {
      attempts++;
      throw const ContextCompactionException('总结模型返回的摘要结构不正确。');
    };
    await actions().send('触发自动压缩');
    expect(attempts, 1);
    expect(fixture.container.read(modelFailoverPromptForProvider(fixture.conversation.id)), isNull);
    expect(
      fixture.container.read(conversationErrorProvider(fixture.conversation.id)),
      contains('总结模型返回的摘要结构不正确'),
    );
  });
}
