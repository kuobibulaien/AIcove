import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_provider_context.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';

AppSettings _buildSettings(List<ProviderAuth> providers) {
  return AppSettings(
    ttsEnabled: true,
    defaultModelName: 'openai:gpt-4o-mini',
    defaultPersonaPrompt: '',
    modelList: const <String>['openai:gpt-4o-mini'],
    allKnownModels: const <String>['openai:gpt-4o-mini'],
    modelDisplayNames: const <String, String>{},
    modelTypes: const <String, String>{},
    modelConfigs: const <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    contextWindowTokens: 272000,
    customModels: const <CustomModel>[],
    providers: providers,
    modelProviderMap: const <String, String>{},
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
  group('TtsProviderContext.resolve', () {
    test('能从 ProviderAuth 解析 voiceProvider apiKey requestFormat 和 model', () {
      final settings = _buildSettings(const <ProviderAuth>[
        ProviderAuth(
          id: 'provider_minimax',
          displayName: 'MiniMax 渠道',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.minimaxi.com/v1',
          models: <String>['speech-2.8-hd'],
          visibleModels: <String>['speech-2.8-hd'],
          customConfig: <String, dynamic>{'requestFormat': 'openai_tts'},
          capabilities: <String>['tts'],
        ),
      ]);

      final context = TtsProviderContext.resolve(
        config: TtsConfig(
          selectedProviderId: 'provider_minimax',
          selectedModelId: 'speech-2.8-hd',
        ),
        settings: settings,
      );

      expect(context.providerAuth?.id, 'provider_minimax');
      expect(context.voiceProvider?.providerId, 'minimax');
      expect(context.apiKey, 'test-key');
      expect(context.requestFormat, 'openai_tts');
      expect(context.selectedModelId, 'speech-2.8-hd');
    });

    test('selectedModelId 不可用时返回 null', () {
      final settings = _buildSettings(const <ProviderAuth>[
        ProviderAuth(
          id: 'provider_sf',
          displayName: '硅基流动',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.siliconflow.cn/v1',
          models: <String>['IndexTeam/IndexTTS-2'],
          visibleModels: <String>['IndexTeam/IndexTTS-2'],
          customConfig: <String, dynamic>{
            'requestFormat': 'siliconflow_indextts',
          },
          capabilities: <String>['tts'],
        ),
      ]);

      final context = TtsProviderContext.resolve(
        config: TtsConfig(
          selectedProviderId: 'provider_sf',
          selectedModelId: 'speech-2.8-hd',
        ),
        settings: settings,
      );

      expect(context.voiceProvider?.providerId, 'siliconflow');
      expect(context.requestFormat, 'siliconflow_indextts');
      expect(context.selectedModelId, isNull);
    });

    test('resolveForSelection 会按传入渠道和模型重新解析上下文', () {
      final settings = _buildSettings(const <ProviderAuth>[
        ProviderAuth(
          id: 'provider_minimax',
          displayName: 'MiniMax 渠道',
          apiKeys: <String>['test-key'],
          apiBaseUrl: 'https://api.minimaxi.com/v1',
          models: <String>['speech-2.8-hd'],
          visibleModels: <String>['speech-2.8-hd'],
          customConfig: <String, dynamic>{'requestFormat': 'openai_tts'},
          capabilities: <String>['tts'],
        ),
        ProviderAuth(
          id: 'provider_sf',
          displayName: '硅基流动',
          apiKeys: <String>['sf-key'],
          apiBaseUrl: 'https://api.siliconflow.cn/v1',
          models: <String>['IndexTeam/IndexTTS-2'],
          visibleModels: <String>['IndexTeam/IndexTTS-2'],
          customConfig: <String, dynamic>{
            'requestFormat': 'siliconflow_indextts',
          },
          capabilities: <String>['tts'],
        ),
      ]);

      final context = TtsProviderContext.resolveForSelection(
        config: TtsConfig(
          selectedProviderId: 'provider_minimax',
          selectedModelId: 'speech-2.8-hd',
        ),
        settings: settings,
        providerId: 'provider_sf',
        modelId: 'IndexTeam/IndexTTS-2',
      );

      expect(context.providerAuth?.id, 'provider_sf');
      expect(context.voiceProvider?.providerId, 'siliconflow');
      expect(context.apiKey, 'sf-key');
      expect(context.selectedModelId, 'IndexTeam/IndexTTS-2');
    });
  });
}
