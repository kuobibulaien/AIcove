import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show ToolEffect;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ProviderChatRequestOptions;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

class _Request {
  _Request(this.config, this.streaming);
  final ApiConfig config;
  final bool streaming;
  final result = Completer<ApiCallResult>();

  void Function() start(String path) {
    final call = ToolCall(id: '', name: 'read', arguments: {'path': path});
    return config.onToolActivity!(call);
  }

  void finish() => result.complete(
    const ApiCallResult(
      replyText: '完成',
      processedText: '完成',
      pluginEvents: [],
      toolResults: [],
    ),
  );
}

/// Only the API boundary is controlled; generation, cancellation, persistence
/// and activity callbacks all run through the real ChatActions.
class _ControlledSend extends ChatSendService {
  _ControlledSend(super.ref);
  final requests = <_Request>[];
  AppSettings apiSettings = segmentedProbeSettings;
  String? apiModel;
  Future<ApiCallResult> Function(ApiConfig config)? run;

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
    settings: apiSettings,
    modelFullId: apiModel ?? overrideModel ?? apiSettings.defaultModelName,
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
    if (run != null) return run!(config);
    // copyWith must retain the callback, as it does in the real runner.
    final request = _Request(config.copyWith(), enableStreaming);
    requests.add(request);
    return request.result.future;
  }
}

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
  }) async => SendMessageRichResult(
    text: '完成',
    toolResults: const [],
    toolCalls: ++requests == 1
        ? const [
            ToolCall(id: '', name: 'read', arguments: {'path': 'real.json'}),
          ]
        : const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SegmentedChatFixture fixture;
  late _ControlledSend service;
  late Directory directory;
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('tool_activity_actions_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        activeConversationProvider.overrideWith((ref) {
          final id = ref.watch(activeConversationIdProvider);
          final conv = ref
              .watch(conversationsProvider)
              .valueOrNull
              ?.firstOrNull;
          return id == null ? null : conv?.copyWith(id: id);
        }),
        chatSendServiceProvider.overrideWith((ref) {
          service = _ControlledSend(ref);
          return service;
        }),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
  });
  tearDown(() async {
    await fixture.dispose();
  });

  String? activity([String? conversationId]) => fixture.container.read(
        conversationToolActivityProvider(
          conversationId ?? fixture.conversation.id,
        ),
      );
  ChatActions actions() => fixture.container.read(chatActionsProvider);
  Future<_Request> requestAt(int index) async {
    await fixture.waitUntil(() => service.requests.length > index);
    return service.requests[index];
  }

  test('真实 ChatActions → Kernel runner → 慢工具执行期间显示活动', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    service.apiSettings = mapUiModelsToAppSettings({
      'model_configs': {
        'openai:test': {
          'chat_capabilities': ['tools'],
        },
      },
    });
    service.apiModel = 'openai:test';
    final runner = KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (_) => _Client(),
    );
    service.run = (config) => runner.executeApiCall(
      config: config,
      sessionId: fixture.conversation.id,
      userText: '执行工具',
      responseProcessors: const [],
      availableTools: [
        AITool(
          name: 'read',
          description: 'read',
          parameters: const {},
          effect: ToolEffect.readDiagnostic,
          handler: (_) async {
            entered.complete();
            await release.future;
            return 'content';
          },
        ),
      ],
    );
    final send = actions().send('执行工具');
    await entered.future.timeout(const Duration(seconds: 10));
    expect(activity(), 'read · real.json');
    release.complete();
    await send;
    expect(activity(), isNull);
  });

  test('并发空 id 工具独立结束，生成收尾主动清除未结束的工具', () async {
    final send = actions().send('调用两个工具');
    final request = await requestAt(0);
    expect(request.streaming, isTrue);
    request.start('first.json');
    expect(activity(), 'read · first.json');
    final endSecond = request.start('second.json');
    expect(activity(), 'read · second.json');
    endSecond();
    expect(activity(), 'read · first.json');

    request.finish();
    await send;
    expect(activity(), isNull);
    request.start('late.json')();
    expect(activity(), isNull);
  });

  test('取消立即清除；重发后旧开始、结束和生成收尾不污染新一轮', () async {
    final oldSend = actions().send('旧请求');
    final old = await requestAt(0);
    final endOld = old.start('old.json');
    expect(activity(), 'read · old.json');
    final interrupt = actions().interruptCurrentGeneration();
    expect(activity(), isNull, reason: '不能等旧工具或异步清理完成');

    final newSend = actions().send('新请求');
    final current = await requestAt(1);
    final endCurrent = current.start('current.json');
    await interrupt;
    expect(activity(), 'read · current.json');
    endOld();
    old.start('late.json')();
    expect(activity(), 'read · current.json');
    old.finish();
    await oldSend;
    expect(activity(), 'read · current.json');
    endCurrent();
    expect(activity(), isNull);
    current.finish();
    await newSend;
    expect(activity(), isNull);
  });

  test('新生成替换旧生成时立即清除，旧回调失效', () async {
    final oldSend = actions().send('旧请求');
    final old = await requestAt(0);
    final endOld = old.start('old.json');
    final newSend = actions().send('替换请求');
    final current = await requestAt(1);
    expect(activity(), isNull);
    current.start('new.json');
    endOld();
    old.start('late.json')();
    expect(activity(), 'read · new.json');
    old.finish();
    await oldSend;
    expect(activity(), 'read · new.json');
    current.finish();
    await newSend;
    expect(activity(), isNull);
  });

  for (final image in [true, false]) {
    test('${image ? '图片' : '文件'}非流式发送也接入活动回调并在生成结束清除', () async {
      final attachment = File(
        '${directory.path}/${image ? 'image.png' : 'file.txt'}',
      );
      await attachment.writeAsBytes([1, 2, 3]);
      final send = image
          ? actions().sendWithImage(attachment.path, text: '看看图片')
          : actions().sendWithFile(attachment.path, text: '看看文件');
      final request = await requestAt(0);
      expect(request.streaming, isFalse);
      request.start('image.json');
      expect(activity(), 'read · image.json');
      request.finish();
      await send;
      expect(activity(), isNull);
    });
  }

  test('工具活动只记在所属会话，切走后结束仍清理原会话', () async {
    final send = actions().send('会话 A');
    final request = await requestAt(0);
    final end = request.start('a.json');
    final id = fixture.container.read(activeConversationIdProvider.notifier);
    id.state = 'conversation_b';
    expect(activity('conversation_b'), isNull);
    expect(activity(), 'read · a.json');
    end();
    expect(activity(), isNull);
    id.state = fixture.conversation.id;
    request.finish();
    await send;
  });
}
