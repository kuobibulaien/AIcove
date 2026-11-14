import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/agent_api.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/preset_script_runtime.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

const _schema = <String, dynamic>{
  'type': 'function',
  'function': {
    'name': 'deliver_text',
    'description': 'Deliver response',
    'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
  },
};

class _Runtime implements PresetScriptRuntime {
  _Runtime(this.transport);
  final bool transport;
  bool prepared = false;

  @override
  List<Map<String, dynamic>> get transportTools =>
      prepared && transport ? [_schema] : [];
  @override
  List<Map<String, dynamic>> get businessTools => [];
  @override
  List<Map<String, dynamic>> get tools => transportTools;
  @override
  String? get toolChoice => transportTools.isEmpty ? null : 'required';
  @override
  List<String> get diagnostics => [];
  @override
  Future<List<Map<String, dynamic>>> prepare(
    List<Map<String, dynamic>> messages,
  ) async {
    prepared = true;
    return messages;
  }

  @override
  Future<void> reset(bool streaming) async {}
  @override
  Future<String> update(
    String cumulativeText, {
    List<Map<String, dynamic>> calls = const [],
  }) async => cumulativeText;
  @override
  Future<({String text, Set<String> consumedIds, Set<int> consumedIndexes})>
  response(String text, List<Map<String, dynamic>> calls) async =>
      (text: text, consumedIds: <String>{}, consumedIndexes: <int>{});
  @override
  Future<String> action(String name, Map<String, dynamic> arguments) async =>
      '';
  @override
  Future<void> close() async {}
}

class _Client extends AgentApiClient {
  _Client(this.beforeOutput);
  final void Function() beforeOutput;

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
    void Function(String)? onTextDelta,
    void Function()? onToolCallsDetected,
    void Function(List<ToolCall> Function())? onToolCallProgress,
    TraceLogger? trace,
    String? turnId,
    int? roundIndex,
    String? traceId,
  }) async {
    beforeOutput();
    onTextDelta?.call('Hello');
    return const SendMessageRichResult(
      text: 'Hello',
      toolResults: [],
      toolCalls: [],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final transport in [false, true]) {
    test(
      'prepared runtime refines transport state before output ($transport)',
      () async {
        final changes = <bool>[];
        final runtime = _Runtime(transport);
        final config =
            ApiConfig(
              settings: mapUiModelsToAppSettings({}),
              modelFullId: 'openai:test',
              providerApiBase: 'https://invalid.test',
              customConfig: const {},
              messages: const [
                {'role': 'user', 'content': 'Hello'},
              ],
              // Deliberately contradict runtime state: scripts may install no
              // transport, while an injected runtime can create one dynamically.
              presetScript: PresetScriptSnapshot(
                transport ? '{"scripts":[]}' : '{"scripts":[{}]}',
              ),
              onTransportStreamingChanged: changes.add,
            ).copyWith(
              messages: const [
                {'role': 'user', 'content': 'Hello'},
              ],
            );
        final client = _Client(() {
          expect(runtime.prepared, isTrue);
          expect(changes, [transport]);
        });
        final result =
            await KernelApiRunner.withAgentClientFactory(
              agentClientFactory: (_) => client,
              openPresetRuntime: (_) async => runtime,
            ).executeApiCall(
              config: config,
              sessionId: 'transport-state',
              userText: 'Hello',
              responseProcessors: const [],
              enableStreaming: true,
            );
        expect(result.replyText, 'Hello');
        expect(changes, [transport]);
      },
    );
  }

  test('Gemini maps required tool choice to ANY', () {
    final body = GeminiAdapter().buildRequestBody(
      model: 'gemini-test',
      messages: const [
        {'role': 'user', 'content': 'Hello'},
      ],
      tools: const [_schema],
      requestOptions: const ProviderChatRequestOptions(toolChoice: 'required'),
    );
    expect((body['toolConfig'] as Map)['functionCallingConfig'], {
      'mode': 'ANY',
    });
  });
}
