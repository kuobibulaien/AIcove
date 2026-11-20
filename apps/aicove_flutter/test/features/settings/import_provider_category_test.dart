import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/settings/data/support/ui_models_store_support.dart';
import 'package:aicove_flutter/src/features/settings/ui_models_api.dart';
import 'package:aicove_flutter/src/features/settings/provider_detail/provider_detail_support.dart';

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

  group('通用渠道不锁定模型用途', () {
    test('OpenAI 绘图分类导入不保存渠道默认类型', () async {
      final before = (await buildApi().fetchAll())['default_model'];
      final stored = await buildApi().importProvider(
        providerId: 'paint',
        apiKey: 'k',
        apiBaseUrl: 'https://api.example.com/v1',
        allModels: const ['gpt-image-1'],
        visibleModels: const ['gpt-image-1'],
        capabilities: const ['image'],
        customConfig: const {'requestFormat': 'openai'},
      );
      final settings = mapUiModelsToAppSettings(stored);
      expect(
        settings.getProvider('paint')!.customConfig['defaultModelType'],
        isNull,
      );
      expect(settings.getModelType('paint:gpt-image-1'), ModelType.image);
      expect(settings.getProvider('paint')!.capabilities, ['image']);
      expect(settings.modelList, isNot(contains('paint:gpt-image-1')));
      expect((await buildApi().fetchAll())['default_model'], before);
    });

    test('旧通用绘图渠道移除默认类型但保留逐模型显式覆盖', () async {
      SharedPreferences.setMockInitialValues({
        'aicove.ui_models.v1': jsonEncode({
          'providers': [
            {
              'id': 'paint',
              'apiKeys': ['k'],
              'apiBaseUrl': 'https://api.example.com/v1',
              'enabled': true,
              'models': ['gpt-4o', 'my-custom-paint'],
              'visible_models': ['gpt-4o', 'my-custom-paint'],
              'capabilities': ['image'],
              'custom_config': {
                'requestFormat': 'openai',
                'defaultModelType': 'image',
              },
            },
          ],
          'model_types': {'paint:my-custom-paint': 'image'},
        }),
      });
      final migrated = mapUiModelsToAppSettings(await buildApi().fetchAll());
      expect(
        migrated.getProvider('paint')!.customConfig['defaultModelType'],
        isNull,
      );
      expect(migrated.getModelType('paint:gpt-4o'), ModelType.chat);
      expect(migrated.getModelType('paint:my-custom-paint'), ModelType.image);
      expect(
        migrated.getProvider('paint')!.capabilities,
        containsAll(['chat', 'image']),
      );
    });

    test('模型用途选择在更新和重新读取后保留', () async {
      await buildApi().importProvider(
        providerId: 'paint',
        apiKey: 'k',
        apiBaseUrl: 'https://api.example.com/v1',
        allModels: const ['gpt-image-1'],
        customConfig: const {'requestFormat': 'openai'},
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.updateProviderModels(
        providerId: 'paint',
        allModels: const ['gpt-image-1', 'gpt-4o', 'my-custom-paint'],
        visibleModels: const ['gpt-4o', 'my-custom-paint'],
        selectedModelTypes: const {'my-custom-paint': ModelType.image},
      );
      await buildApi().updateProvider(providerId: 'paint', displayName: '改名');
      await notifier.updateProviderModels(
        providerId: 'paint',
        allModels: const ['gpt-image-1', 'gpt-4o', 'my-custom-paint'],
        visibleModels: const ['gpt-4o', 'my-custom-paint'],
      );
      final saved = mapUiModelsToAppSettings(await buildApi().fetchAll());
      expect(saved.getModelType('paint:gpt-4o'), ModelType.chat);
      expect(saved.getModelType('paint:my-custom-paint'), ModelType.image);
      expect(saved.modelTypes['paint:my-custom-paint'], 'image');
      expect(saved.modelList, contains('paint:gpt-4o'));
      expect(saved.modelList, isNot(contains('paint:my-custom-paint')));
    });
  });

  test('隐藏的远端对话模型不参与可见图像渠道能力', () async {
    final api = buildApi();
    await api.importProvider(
      providerId: 'paint',
      apiKey: 'k',
      apiBaseUrl: 'https://example.invalid/v1',
      allModels: const ['gpt-4o', 'Kwai-Kolors/Kolors', 'my-custom-paint'],
      visibleModels: const ['gpt-4o'],
      customConfig: const {'requestFormat': 'openai'},
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .updateProviderModels(
          providerId: 'paint',
          allModels: const ['gpt-4o', 'Kwai-Kolors/Kolors', 'my-custom-paint'],
          visibleModels: const ['my-custom-paint'],
          hiddenModels: const ['gpt-4o', 'Kwai-Kolors/Kolors'],
          selectedModelTypes: const {'my-custom-paint': ModelType.image},
        );
    final settings = mapUiModelsToAppSettings(await api.fetchAll());
    final provider = settings.getProvider('paint')!;
    expect(provider.capabilities, ['image']);
    expect(settings.getModelType('paint:gpt-4o'), ModelType.chat);
    expect(settings.modelList.where((id) => id.startsWith('paint:')), isEmpty);
    expect(
      settings.getProviderVisibleModelsByType('paint', type: ModelType.image),
      ['my-custom-paint'],
    );
    expect(
      ProviderDetailRequestFormat.forProvider(provider, settings: settings),
      ProviderDetailRequestFormat.imageFormats,
    );
  });

  test('用途覆盖清除最后一个键，并以 scoped chat 遮蔽旧裸 ID', () async {
    final api = buildApi();
    await api.importProvider(
      providerId: 'mixed',
      apiKey: 'k',
      apiBaseUrl: 'https://example.invalid/v1',
      allModels: const ['gpt-4o'],
      customConfig: const {'requestFormat': 'openai'},
      modelTypeOverrides: const {'gpt-4o': 'image'},
    );
    final imported = await api.fetchAll();
    await api.updatePartial({
      'providers': (imported['providers'] as List)
          .where((provider) => provider['id'] == 'mixed')
          .toList(),
      'model_types': {'mixed:gpt-4o': 'image'},
    });
    final cleared = await api.updateProvider(
      providerId: 'mixed',
      modelTypeOverrides: const {'gpt-4o': 'chat'},
    );
    expect(cleared['model_types'], isEmpty);
    await api.updatePartial({
      'model_types': {'gpt-4o': 'image'},
    });
    final stored = await api.updateProvider(
      providerId: 'mixed',
      modelTypeOverrides: const {'gpt-4o': 'chat'},
    );
    expect(stored['model_types'], {'gpt-4o': 'image', 'mixed:gpt-4o': 'chat'});
    expect(
      mapUiModelsToAppSettings(stored).getProvider('mixed')!.capabilities,
      ['chat'],
    );
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
