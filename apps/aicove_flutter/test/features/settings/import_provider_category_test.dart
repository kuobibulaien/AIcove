import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  UiModelsApi buildApi() => UiModelsApi(
    httpClient: MockClient((req) async => throw StateError('unexpected')),
  );

  test('语音分类导入时模型整体定型为 tts，且不改默认对话模型', () async {
    final api = buildApi();
    final before = (await api.fetchAll())['default_model'];

    final stored = await api.importProvider(
      providerId: 'fish_audio_custom',
      apiKey: 'k',
      apiBaseUrl: 'https://api.fish.audio/v1',
      allModels: const <String>['s2.1-pro-free', 's2.1-pro'],
      visibleModels: const <String>['s2.1-pro-free', 's2.1-pro'],
      capabilities: const <String>['tts'],
      customConfig: const <String, dynamic>{'requestFormat': 'fish_audio'},
    );
    final settings = mapUiModelsToAppSettings(stored);
    final provider = settings.getProvider('fish_audio_custom')!;

    expect(provider.capabilities, <String>['tts']);
    expect(
      settings.getProviderVisibleModelsByType(
        'fish_audio_custom',
        type: ModelType.tts,
      ),
      <String>['s2.1-pro-free', 's2.1-pro'],
    );
    expect(stored['default_model'], before);
  });

  test('对话分类导入仍按模型名推断类型', () async {
    final stored = await buildApi().importProvider(
      providerId: 'openai_custom',
      apiKey: 'k',
      apiBaseUrl: 'https://api.example.com/v1',
      allModels: const <String>['gpt-4o', 'tts-1'],
      capabilities: const <String>['chat'],
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
    );
    final provider = mapUiModelsToAppSettings(
      stored,
    ).getProvider('openai_custom')!;

    expect(provider.capabilities, containsAll(<String>['chat', 'tts']));
  });

  group('语音渠道存储规整', () {
    Map<String, dynamic> provider(
      String id,
      String url,
      List<String> models, {
      List<String> capabilities = const <String>['tts'],
      Map<String, dynamic>? customConfig,
    }) => <String, dynamic>{
      'id': id,
      'apiKeys': <String>['k'],
      'apiBaseUrl': url,
      'enabled': true,
      'models': models,
      'visible_models': models,
      'capabilities': capabilities,
      if (customConfig != null) 'custom_config': customConfig,
    };

    test('内置 Fish 渠道的模型即使能力被推断成对话，也规整为语音', () {
      final data = normalizeUiModelsStoreData(<String, dynamic>{
        'providers': [
          provider(
            'fish_audio',
            'https://api.fish.audio/v1',
            const <String>['s2.1-pro-free', 's2.1-pro'],
            capabilities: const <String>['chat'],
            customConfig: const <String, dynamic>{
              'requestFormat': 'fish_audio',
            },
          ),
        ],
      });
      final settings = mapUiModelsToAppSettings(data);

      expect(settings.getProvider('fish_audio')!.capabilities, <String>['tts']);
      expect(
        settings.getProviderModelsByType('fish_audio', type: ModelType.chat),
        isEmpty,
      );
    });

    test('旧语音渠道补成显式格式，硅基流动迁到 OpenAI TTS', () {
      final data = normalizeUiModelsStoreData(<String, dynamic>{
        'providers': [
          provider(
            'aliyun',
            'https://dashscope.aliyuncs.com/compatible-mode/v1',
            const <String>['cosyvoice-v3-plus'],
          ),
          provider(
            'sf',
            'https://api.siliconflow.cn/v1',
            const <String>['FunAudioLLM/CosyVoice2-0.5B'],
            customConfig: const <String, dynamic>{
              'requestFormat': 'siliconflow_indextts',
            },
          ),
          provider(
            'deepseek',
            'https://api.deepseek.com/v1',
            const <String>['deepseek-chat'],
            capabilities: const <String>['chat'],
          ),
        ],
      });
      final settings = mapUiModelsToAppSettings(data);

      expect(
        settings.getProvider('aliyun')!.customConfig['requestFormat'],
        'aliyun',
      );
      expect(
        settings.getProvider('sf')!.customConfig['requestFormat'],
        'openai_tts',
      );
      expect(settings.getProvider('sf')!.capabilities, <String>['tts']);
      expect(
        settings.getProvider('deepseek')!.customConfig['requestFormat'],
        isNull,
      );
    });
  });
}
