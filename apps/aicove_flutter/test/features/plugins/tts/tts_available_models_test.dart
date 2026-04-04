import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_available_models.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

AppSettings _buildSettings(List<ProviderAuth> providers) {
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: 'openai:gpt-4o-mini',
    defaultPersonaPrompt: '',
    modelList: const <String>[
      'provider_minimax:speech-2.8-hd',
      'provider_chat:gpt-4o-mini',
      'provider_no_key:speech-2.8-hd',
    ],
    allKnownModels: const <String>[
      'provider_minimax:speech-2.8-hd',
      'provider_chat:gpt-4o-mini',
      'provider_no_key:speech-2.8-hd',
    ],
    modelDisplayNames: const <String, String>{
      'provider_minimax:speech-2.8-hd': 'MiniMax TTS',
      'provider_chat:gpt-4o-mini': '聊天模型',
      'provider_no_key:speech-2.8-hd': '无 Key 模型',
    },
    modelTypes: const <String, String>{
      'provider_minimax:speech-2.8-hd': 'tts',
      'provider_chat:gpt-4o-mini': 'chat',
      'provider_no_key:speech-2.8-hd': 'tts',
    },
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 20,
    customModels: const <CustomModel>[],
    providers: providers,
    modelProviderMap: const <String, String>{
      'provider_minimax:speech-2.8-hd': 'provider_minimax',
      'provider_chat:gpt-4o-mini': 'provider_chat',
      'provider_no_key:speech-2.8-hd': 'provider_no_key',
    },
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: const MessageFormatConfig(),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    autoReplySettings: const AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: '#FF6B9D',
  );
}

void main() {
  test('buildConfiguredTtsModels 只返回已启用且已配置 key 的 TTS 模型', () {
    final settings = _buildSettings(const <ProviderAuth>[
      ProviderAuth(
        id: 'provider_minimax',
        displayName: 'MiniMax 渠道',
        apiKeys: <String>['test-key'],
        apiBaseUrl: 'https://api.minimaxi.com/v1',
        models: <String>['speech-2.8-hd'],
        visibleModels: <String>['speech-2.8-hd'],
        capabilities: <String>['tts'],
      ),
      ProviderAuth(
        id: 'provider_chat',
        displayName: '聊天渠道',
        apiKeys: <String>['chat-key'],
        apiBaseUrl: 'https://api.openai.com/v1',
        models: <String>['gpt-4o-mini'],
        visibleModels: <String>['gpt-4o-mini'],
        capabilities: <String>['chat'],
      ),
      ProviderAuth(
        id: 'provider_no_key',
        displayName: '未配 Key',
        apiKeys: <String>['   '],
        apiBaseUrl: 'https://api.minimaxi.com/v1',
        models: <String>['speech-2.8-hd'],
        visibleModels: <String>['speech-2.8-hd'],
        capabilities: <String>['tts'],
      ),
    ]);

    final models = buildConfiguredTtsModels(settings);

    expect(models, hasLength(1));
    expect(models.single.providerId, 'provider_minimax');
    expect(models.single.modelId, 'speech-2.8-hd');
    expect(models.single.providerName, 'MiniMax 渠道');
    expect(models.single.displayName, 'MiniMax TTS');
    expect(models.single.voiceProviderId, 'minimax');
  });
}
