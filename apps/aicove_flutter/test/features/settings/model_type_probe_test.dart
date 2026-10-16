import 'dart:convert';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_model_probe.dart';
import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 1x1 transparent PNG
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

AppSettings _settingsWith(ProviderAuth provider) => AppSettings(
  ttsEnabled: true,
  defaultModelName: '',
  defaultPersonaPrompt: '',
  modelList: const <String>[],
  allKnownModels: const <String>[],
  modelDisplayNames: const <String, String>{},
  modelTypes: const <String, String>{},
  modelConfigs: const <String, ModelConfig>{},
  apiKey: '',
  apiBaseUrl: '',
  imageGenerationEnabled: false,
  maxFileUploadMB: 10,
  contextWindowTokens: 272000,
  customModels: const <CustomModel>[],
  providers: [provider],
  modelProviderMap: const <String, String>{},
  backendApiKey: '',
  messageChunkingEnabled: true,
  messageFormatConfig: const MessageFormatConfig(
    enableChunking: true,
    chunkPunctuations: <String>['。'],
    minSegmentLength: 1,
  ),
  textScaleFactor: 1.0,
  uiScaleFactor: 1.0,
  imagePreviewScale: 1.0,
  autoReplySettings: const AutoReplySettings(),
  globalBackgroundColor: GlobalBackgroundColor.white,
  chatBackgroundColor: ChatBackgroundColor.defaultColor,
  isDarkMode: false,
  useSystemTheme: true,
  accentColor: 'FC96AA',
  hideUserAvatar: false,
  defaultChatModels: const <String>[],
);

void main() {
  test('image model test generates through the image endpoint', () async {
    final requests = <http.Request>[];
    final api = UiModelsApi(
      httpClient: MockClient((req) async {
        requests.add(req);
        return http.Response(
          jsonEncode({
            'data': [
              {'b64_json': _png},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await api.testModel(
      providerId: 'openai',
      apiKey: 'sk-test',
      apiBaseUrl: 'https://img.example.com/v1',
      modelId: 'gpt-image-1',
      modelType: ModelType.image,
    );

    expect(result, contains('生图成功'));
    expect(requests.single.url.path, '/v1/images/generations');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['model'], 'gpt-image-1');
    expect(body['n'], 1);
  });

  test('image model test surfaces upstream errors as failure', () async {
    final api = UiModelsApi(
      httpClient: MockClient((_) async => http.Response('bad model', 404)),
    );
    expect(
      api.testModel(
        providerId: 'openai',
        apiKey: 'sk-test',
        apiBaseUrl: 'https://img.example.com/v1',
        modelId: 'missing',
        modelType: ModelType.image,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('tts model test synthesizes a short line via the speech endpoint',
      () async {
    final provider = ProviderAuth(
      id: 'speech_relay',
      apiKeys: const ['sk-test'],
      apiBaseUrl: 'https://tts.example.com/v1',
      models: const ['tts-1'],
      visibleModels: const ['tts-1'],
      capabilities: const ['tts'],
    );
    final requests = <http.Request>[];
    final result = await http.runWithClient(
      () => TtsModelProbe.run(
        settings: _settingsWith(provider),
        provider: provider,
        apiKey: 'sk-test',
        modelId: 'tts-1',
      ),
      () => MockClient((req) async {
        requests.add(req);
        return http.Response.bytes(
          List<int>.filled(64, 1),
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      }),
    );

    expect(result, contains('语音合成成功'));
    final speech = requests.singleWhere(
      (r) => r.url.path.endsWith('/audio/speech'),
    );
    final body = jsonDecode(speech.body) as Map<String, dynamic>;
    expect(body['model'], 'tts-1');
    expect(body['input'], TtsModelProbe.probeText);
  });
}
