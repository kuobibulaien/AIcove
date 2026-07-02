import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/base_plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
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
      modelRef: ModelConfig(
        chatCapabilities: <String>['tools'],
      ),
    },
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: true,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[
      ProviderAuth(
        id: 'openai',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
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
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.auto),
  );
}

class _SplitInlineImageStreamingClient extends AgentApiClient {
  _SplitInlineImageStreamingClient(Duration timeout) : super(timeout: timeout);

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
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    throw UnsupportedError('这个测试只应该命中流式调用');
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
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('第一句。<im');
    onTextDelta?.call('age>1girl, cat ears');
    onTextDelta?.call(', masterpiece</image>第二句。');

    return const SendMessageRichResult(
      text: '第一句。<image>1girl, cat ears, masterpiece</image>第二句。',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

class _SplitThinkStreamingClient extends AgentApiClient {
  _SplitThinkStreamingClient(Duration timeout) : super(timeout: timeout);

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
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    throw UnsupportedError('这个测试只应该命中流式调用');
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
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('第一句。<th');
    onTextDelta?.call('ink>内部思考过程');
    onTextDelta?.call('</think>第二句。');

    return const SendMessageRichResult(
      text: '第一句。<think>内部思考过程</think>第二句。',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

class _StrayThinkCloseStreamingClient extends AgentApiClient {
  _StrayThinkCloseStreamingClient(Duration timeout) : super(timeout: timeout);

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
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    throw UnsupportedError('这个测试只应该命中流式调用');
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
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('第一句。</think>');
    onTextDelta?.call('第二句。');

    return const SendMessageRichResult(
      text: '第一句。</think>第二句。',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

class _AttributeImageTagStreamingClient extends AgentApiClient {
  _AttributeImageTagStreamingClient(Duration timeout) : super(timeout: timeout);

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
    List<Map<String, dynamic>>? tools,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) {
    throw UnsupportedError('这个测试只应该命中流式调用');
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
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('第一句。<image sou');
    onTextDelta?.call('rce="history">保留这段');
    onTextDelta?.call('</image>第二句。');

    return const SendMessageRichResult(
      text: '第一句。<image source="history">保留这段</image>第二句。',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

class _InlineImageStripPlugin extends BasePlugin {
  _InlineImageStripPlugin()
      : super(
          metadata: const PluginMetadata(
            id: 'image',
            name: 'Image',
            description: 'strip inline image tags for stream filter test',
            version: '1.0.0',
            author: 'test',
            icon: Icons.image,
          ),
        );

  @override
  bool get enabled => true;

  @override
  Future<String?> getSystemPrompt({
    String? userMessage,
    bool supportsToolCalling = false,
  }) async {
    return null;
  }

  @override
  Future<PluginProcessResult> processResponse(String text) async {
    final processed = text.replaceAll(
      RegExp(r'<image>([\s\S]*?)</image>', caseSensitive: false),
      '',
    );
    return PluginProcessResult(
      processedText: processed,
      events: const <PluginEvent>[],
      contents: const [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'stream callback should receive visible text only before inline image tags',
      () async {
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '帮我画一只猫',
        },
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) =>
          _SplitInlineImageStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_image_prompt',
      userText: '帮我画一只猫',
      effectivePlugins: <Plugin>[_InlineImageStripPlugin()],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
      maxRounds: 1,
    );

    expect(streamedDeltas, <String>['第一句。', '第二句。']);
    expect(streamedDeltas.join(), isNot(contains('<image')));
    expect(streamedDeltas.join(), isNot(contains('cat ears')));
    expect(result.processedText, '第一句。第二句。');
  });

  test('stream callback should hide think tag content and markers', () async {
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '你刚才在想什么',
        },
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => _SplitThinkStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_think_tag',
      userText: '你刚才在想什么',
      effectivePlugins: const <Plugin>[],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
      maxRounds: 1,
    );

    expect(streamedDeltas, <String>['第一句。', '第二句。']);
    expect(streamedDeltas.join(), isNot(contains('<think')));
    expect(streamedDeltas.join(), isNot(contains('</think>')));
    expect(streamedDeltas.join(), isNot(contains('内部思考过程')));
    expect(result.replyText, '第一句。第二句。');
    expect(result.processedText, '第一句。第二句。');
  });

  test('stream callback should strip stray think close tag fragments',
      () async {
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '继续',
        },
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => _StrayThinkCloseStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_think_stray_close',
      userText: '继续',
      effectivePlugins: const <Plugin>[],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
      maxRounds: 1,
    );

    expect(streamedDeltas, <String>['第一句。', '第二句。']);
    expect(streamedDeltas.join(), isNot(contains('</think>')));
    expect(result.replyText, '第一句。第二句。');
    expect(result.processedText, '第一句。第二句。');
  });

  test('stream callback 不应把带属性的 image 标签误当成 inline 生图标签', () async {
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      toolPrefs: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '继续',
        },
      ],
    );

    final runner = ChatSendApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) =>
          _AttributeImageTagStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_image_attr',
      userText: '继续',
      effectivePlugins: const <Plugin>[],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
      maxRounds: 1,
    );

    expect(
      streamedDeltas.join(),
      '第一句。<image source="history">保留这段</image>第二句。',
    );
    expect(
      result.replyText,
      '第一句。<image source="history">保留这段</image>第二句。',
    );
    expect(
      result.processedText,
      '第一句。<image source="history">保留这段</image>第二句。',
    );
  });
}
