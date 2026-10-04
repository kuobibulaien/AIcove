import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';
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
}
