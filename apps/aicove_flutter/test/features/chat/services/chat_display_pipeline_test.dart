import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall;
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/silly_tavern_preset.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/plugin.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

const _settings = AppSettings(
  ttsEnabled: false,
  defaultModelName: 'openai:gpt-4o-mini',
  defaultPersonaPrompt: '',
  modelList: [],
  allKnownModels: [],
  modelDisplayNames: {},
  modelTypes: {},
  modelConfigs: {},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: [],
  providers: [],
  modelProviderMap: {},
  backendApiKey: '',
  messageChunkingEnabled: false,
  messageFormatConfig: MessageFormatConfig(),
  textScaleFactor: 1,
  uiScaleFactor: 1,
  imagePreviewScale: 1,
  autoReplySettings: AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: false,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
);

class _ReplyClient extends http.BaseClient {
  _ReplyClient(this.text, {this.reasoning = '', this.toolRound = false});
  final String text;
  final String reasoning;
  final bool toolRound;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    final firstToolRound = toolRound && calls == 1;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': !toolRound || firstToolRound
                      ? text
                      : '<think>最后思考</think>SECRET完成',
                  'reasoning_content': !toolRound || firstToolRound
                      ? reasoning
                      : '',
                  if (firstToolRound)
                    'tool_calls': [
                      {
                        'id': 'read-1',
                        'type': 'function',
                        'function': {'name': 'read', 'arguments': '{}'},
                      },
                    ],
                },
                'finish_reason': firstToolRound ? 'tool_calls' : 'stop',
              },
            ],
          }),
        ),
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

SillyTavernRegexScript _script(String pattern, String replacement) =>
    SillyTavernRegexScript(
      id: 'display',
      name: 'display',
      source: 'standard',
      disabled: false,
      runOnEdit: false,
      findRegex: pattern,
      replaceString: replacement,
      trimStrings: const [],
      placements: const [2],
      substituteRegex: 0,
      minDepth: null,
      maxDepth: null,
      markdownOnly: false,
      promptOnly: false,
    );

Future<ApiCallResult> _run(
  String text, {
  String reasoning = '',
  List<SillyTavernRegexScript> scripts = const [],
  List<PluginResponseProcessor> processors = const [],
  List<AITool> tools = const [],
  http.Client? client,
  Future<void> Function(List<ReplyRound>, List<ToolCall>)? onToolRounds,
}) =>
    KernelApiRunner.withAgentClientFactory(
      agentClientFactory: (timeout) => AgentApiClient(
        client: client ?? _ReplyClient(text, reasoning: reasoning),
        timeout: timeout,
      ),
    ).executeApiCall(
      config: ApiConfig(
        settings: _settings,
        modelFullId: 'openai:gpt-4o-mini',
        providerApiBase: 'https://example.test/v1',
        providerApiKey: 'test',
        customConfig: const {},
        messages: const [
          {'role': 'user', 'content': '继续'},
        ],
        tools: [for (final tool in tools) tool.toOpenAISchema()],
        onToolRounds: onToolRounds,
        presetRegexScripts: scripts,
        presetRegexAuthorized: true,
        presetStreamResponse: false,
      ),
      sessionId: 'display-test',
      userText: '继续',
      responseProcessors: processors,
      availableTools: tools,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('think is extracted before display regex can erase it', () async {
    final result = await _run(
      '<think>私有思考</think>SECRET',
      scripts: [_script('/[\\s\\S]+/g', 'VISIBLE')],
    );
    expect(result.reasoning, '私有思考');
    expect(result.rawReplyText, 'SECRET');
    expect(result.replyText, 'VISIBLE');
  });

  test('native reasoning wins without duplicating inline think', () async {
    final result = await _run('<THINK>重复思考</THINK>正文', reasoning: '原生思考');
    expect(result.reasoning, '原生思考');
    expect(result.replyText, '正文');
  });

  test(
    'display regex transforms prose but not first-party tag payload',
    () async {
      String? pluginInput;
      final result = await _run(
        'SECRET <tts voice="a>b">SECRET</tts> <sticker>x</sticker>',
        scripts: [_script('/SECRET/g', 'VISIBLE')],
        processors: [
          ResponseFunction('capture', (text) async {
            pluginInput = text;
            return PluginProcessResult(processedText: text, events: const []);
          }),
        ],
      );
      expect(
        result.replyText,
        'VISIBLE <tts voice="a>b">SECRET</tts> <sticker>x</sticker>',
      );
      expect(pluginInput, result.replyText);
    },
  );

  test('copied placeholders restore each original tag only once', () async {
    final result = await _run(
      '<tts>声音</tts>',
      scripts: [_script(r'/^([\s\S]*)$/', r'$1$1')],
    );
    expect(result.replyText, '<tts>声音</tts>');
  });

  test('deleted placeholders do not resurrect their plugin tags', () async {
    final result = await _run(
      '前<tts>声音</tts>后',
      scripts: [_script('/[\\s\\S]+/g', '正文')],
    );
    expect(result.replyText, '正文');
  });

  test(
    'tool snapshot and final rounds keep raw and display independently',
    () async {
      List<ReplyRound>? snapshot;
      final processedRounds = <String>[];
      final result = await _run(
        '',
        processors: [
          ResponseFunction('count', (text) async {
            processedRounds.add(text);
            return PluginProcessResult(
              processedText: '$text!processed',
              events: const [],
            );
          }),
        ],
        client: _ReplyClient(
          '<think>工具前思考</think>SECRET准备\n<image></image>',
          toolRound: true,
        ),
        scripts: [_script('/SECRET/g', 'VISIBLE')],
        tools: [
          AITool(
            name: 'read',
            description: 'read',
            parameters: const {},
            handler: (_) async => 'OK',
          ),
        ],
        onToolRounds: (rounds, calls) async {
          snapshot = rounds;
          expect(processedRounds, isEmpty);
        },
      );
      expect(processedRounds, ['VISIBLE准备', 'VISIBLE完成']);
      expect(result.replyRounds.map((round) => round.processedText), [
        'VISIBLE准备!processed',
        'VISIBLE完成!processed',
      ]);
      expect(snapshot, hasLength(1));
      expect(snapshot!.single.rawText, 'SECRET准备');
      expect(snapshot!.single.replyText, 'VISIBLE准备');
      expect(snapshot!.single.reasoning, '工具前思考');
      expect(result.replyRounds, hasLength(2));
      expect(result.replyRounds.map((round) => round.rawText), [
        'SECRET准备',
        'SECRET完成',
      ]);
      expect(result.replyRounds.map((round) => round.replyText), [
        'VISIBLE准备',
        'VISIBLE完成',
      ]);
      expect(result.replyRounds.map((round) => round.reasoning), [
        '工具前思考',
        '最后思考',
      ]);
    },
  );
}
