import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin_metadata.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'api_runner_variants.dart';
import 'test_plugin_support.dart';

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
    contextWindowTokens: 272000,
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
    callFlowSettings: CallFlowSettings(mode: CallFlowMode.call),
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
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

class _StickerStreamingClient extends AgentApiClient {
  _StickerStreamingClient(Duration timeout, this.chunks) : super(timeout: timeout);

  final List<String> chunks;

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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    for (final chunk in chunks) {
      onTextDelta?.call(chunk);
    }
    return SendMessageRichResult(
      text: chunks.join(),
      toolResults: const [],
    );
  }
}

class _SplitOptionsStreamingClient extends AgentApiClient {
  _SplitOptionsStreamingClient(Duration timeout) : super(timeout: timeout);

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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('正文。<opt');
    onTextDelta?.call('ions><option>靠近</option>');
    onTextDelta?.call('<option>离开</option></options>');

    return const SendMessageRichResult(
      text: '正文。<options><option>靠近</option><option>离开</option></options>',
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
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

class _InlineImageStripPlugin extends TestPlugin {
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

class _StrayImageCloseStreamingClient extends AgentApiClient {
  _StrayImageCloseStreamingClient(Duration timeout) : super(timeout: timeout);

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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    // 开头：真孤立 </image>（跨 chunk）；中段：带属性配对标签；尾部：再一个孤立 </image>。
    onTextDelta?.call('第一句。</im');
    onTextDelta?.call('age><image source="history">保留');
    onTextDelta?.call('这段</image>尾部</image>完');

    return const SendMessageRichResult(
      text: '第一句。</image><image source="history">保留这段</image>尾部</image>完',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

class _SplitPresetThinkStreamingClient extends AgentApiClient {
  _SplitPresetThinkStreamingClient(Duration timeout) : super(timeout: timeout);

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
    String? providerApiBase,
    String? providerApiKey,
    Map<String, dynamic>? customConfig,
    ProviderChatRequestOptions? requestOptions,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function() snapshot)? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    onTextDelta?.call('<think');
    onTextDelta?.call('_nya~>想一想</think_nya~>');
    onTextDelta?.call('<thinking>再想</thinking>正文。');

    return const SendMessageRichResult(
      text: '<think_nya~>想一想</think_nya~><thinking>再想</thinking>正文。',
      toolResults: <Map<String, dynamic>>[],
    );
  }
}

void _runAll(RunnerFactory createRunner) {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (chunks, visible) in <(List<String>, String)>[
    (['晚安。<st', 'icker tag="晚安', '"/', '>好梦。'], '晚安。好梦。'),
    (['前<STICKER TAG="开>心"', '/>后'], '前后'),
    (['前<sticker tag="收到">收到啦</sti', 'cker>后'], '前收到啦后'),
    (['前<sticker tag="收到">收到啦</sticker><think>内部</think>后'], '前收到啦后'),
    (['前<stickers>普通文字</stickers>后'], '前<stickers>普通文字</stickers>后'),
  ]) {
    test('stream hides sticker markup without losing following text: $chunks', () async {
      final raw = chunks.join();
      final runner = createRunner(
        agentClientFactory: (timeout) => _StickerStreamingClient(timeout, chunks),
      );
      final deltas = <String>[];
      final result = await runner.executeApiCall(
        config: ApiConfig(
          settings: _buildTestSettings(),
          modelFullId: 'openai:gpt-3.5-turbo',
          providerApiBase: 'https://api.openai.com/v1',
          providerApiKey: 'test-key',
          customConfig: const {},
          messages: const [{'role': 'user', 'content': '晚安'}],
        ),
        sessionId: 'sticker_stream',
        userText: '晚安',
        responseProcessors: const [],
        enableStreaming: true,
        onStreamTextDelta: deltas.add,
      );
      expect(deltas.join(), visible);
      expect(result.rawReplyText, raw);
    });
  }

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
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '帮我画一只猫',
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) =>
          _SplitInlineImageStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_image_prompt',
      userText: '帮我画一只猫',
      responseProcessors: testProcessors(<TestPlugin>[_InlineImageStripPlugin()]),
      availableTools: testTools(<TestPlugin>[_InlineImageStripPlugin()]),
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
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
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '你刚才在想什么',
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => _SplitThinkStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_think_tag',
      userText: '你刚才在想什么',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
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
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '继续',
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => _StrayThinkCloseStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_think_stray_close',
      userText: '继续',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
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
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '继续',
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) =>
          _AttributeImageTagStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_image_attr',
      userText: '继续',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
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

  test('stream callback 剥离真孤立 </image>，同时保留带属性配对标签', () async {
    final settings = _buildTestSettings();
    final config = ApiConfig(
      settings: settings,
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'content': '继续',
        },
      ],
    );

    final runner = createRunner(
      agentClientFactory: (timeout) => _StrayImageCloseStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_stray_image_close',
      userText: '继续',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
    );

    expect(
      streamedDeltas.join(),
      '第一句。<image source="history">保留这段</image>尾部完',
    );
  });

  test('stream callback hides dialogue options but keeps them in the reply',
      () async {
    final config = ApiConfig(
      settings: _buildTestSettings(),
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '接下来呢'},
      ],
    );
    final runner = createRunner(
      agentClientFactory: (timeout) => _SplitOptionsStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    final result = await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_options',
      userText: '接下来呢',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
    );

    expect(streamedDeltas.join(), '正文。');
    expect(result.replyText, contains('<option>离开</option></options>'));
  });

  test('stream callback keeps preset thinking tags for the fold projection',
      () async {
    final config = ApiConfig(
      settings: _buildTestSettings(),
      modelFullId: 'openai:gpt-3.5-turbo',
      providerApiBase: 'https://api.openai.com/v1',
      providerApiKey: 'test-key',
      customConfig: const <String, dynamic>{},
      messages: const <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': '在吗'},
      ],
    );
    final runner = createRunner(
      agentClientFactory: (timeout) => _SplitPresetThinkStreamingClient(timeout),
    );
    final streamedDeltas = <String>[];

    await runner.executeApiCall(
      config: config,
      sessionId: 'conv_stream_filter_preset_think',
      userText: '在吗',
      responseProcessors: const [],
      enableStreaming: true,
      onStreamTextDelta: streamedDeltas.add,
    );

    expect(
      streamedDeltas.join(),
      '<think_nya~>想一想</think_nya~><thinking>再想</thinking>正文。',
    );
  });
}

void main() {
  for (final (variant, createRunner) in apiRunnerVariants) {
    group(variant, () => _runAll(createRunner));
  }
}
