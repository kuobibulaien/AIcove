import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/settings/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failed import keeps appSettingsProvider in data state', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initial = await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await expectLater(
      notifier.importCustomModel(
        name: null,
        apiKey: 'invalid-key',
        apiBaseUrl: 'http://[::1',
        provider: 'openai',
        capabilities: const ['chat'],
        modelType: 'chat',
        customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      ),
      throwsA(isA<Exception>()),
    );

    final state = container.read(appSettingsProvider);
    expect(state.hasError, isFalse);
    expect(state.isLoading, isFalse);

    final after = state.requireValue;
    expect(after.providers.length, initial.providers.length);
    expect(after.defaultModelName, initial.defaultModelName);
  });

  test('import with explicit empty model list still saves provider', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.importCustomModel(
      name: null,
      apiKey: 'dummy-key',
      apiBaseUrl: 'https://example.invalid/v1',
      provider: 'openai',
      capabilities: const <String>['chat'],
      modelType: 'chat',
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      allModels: const <String>[],
      visibleModels: const <String>[],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere((p) => p.id == 'openai');
    expect(provider.models, isEmpty);
    expect(provider.visibleModels, isEmpty);
  });

  test('importing openai provider twice should not overwrite old provider',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.importCustomModel(
      name: null,
      apiKey: 'key-1',
      apiBaseUrl: 'https://api.first.example/v1',
      provider: 'openai',
      displayName: '渠道A',
      capabilities: const <String>['chat'],
      modelType: 'chat',
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      allModels: const <String>['gpt-4o-mini'],
      visibleModels: const <String>['gpt-4o-mini'],
    );

    await notifier.importCustomModel(
      name: null,
      apiKey: 'key-2',
      apiBaseUrl: 'https://api.second.example/v1',
      provider: 'openai',
      displayName: '渠道B',
      capabilities: const <String>['chat'],
      modelType: 'chat',
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      allModels: const <String>['gpt-4o-mini'],
      visibleModels: const <String>['gpt-4o-mini'],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final first = settings.providers.firstWhere((p) => p.id == 'openai');
    final second = settings.providers.firstWhere((p) => p.id == 'openai__2');

    expect(first.apiBaseUrl, 'https://api.first.example/v1');
    expect(second.apiBaseUrl, 'https://api.second.example/v1');
    expect(second.visibleModels, contains('gpt-4o-mini'));
  });

  test('model chat capabilities can be set and cleared per model', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.importCustomModel(
      name: null,
      apiKey: 'key-cap',
      apiBaseUrl: 'https://api.cap.example/v1',
      provider: 'openai',
      capabilities: const <String>['chat'],
      modelType: 'chat',
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      allModels: const <String>['gpt-4o'],
      visibleModels: const <String>['gpt-4o'],
    );

    const modelRef = 'openai:gpt-4o';
    await notifier.updateModelConfig(
      modelId: modelRef,
      chatCapabilities: const <String>['tools'],
    );

    var settings = container.read(appSettingsProvider).requireValue;
    expect(settings.getModelConfig(modelRef).chatCapabilities, ['tools']);
    expect(
      settings.hasChatModelCapability(modelRef, ChatModelCapability.tools),
      isTrue,
    );
    expect(
      settings.hasChatModelCapability(modelRef, ChatModelCapability.vision),
      isFalse,
    );

    await notifier.updateModelConfig(
      modelId: modelRef,
      clearChatCapabilities: true,
    );

    settings = container.read(appSettingsProvider).requireValue;
    expect(settings.getModelConfig(modelRef).chatCapabilities, isNull);
    expect(
      settings.hasChatModelCapability(modelRef, ChatModelCapability.vision),
      isTrue,
    );
  });

  test('disabled providers are excluded from model list and defaults',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'enabled',
          'displayName': '启用渠道',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://enabled.example/v1',
          'enabled': true,
          'models': <String>['model-on'],
          'visible_models': <String>['model-on'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
        {
          'id': 'disabled',
          'displayName': '禁用渠道',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://disabled.example/v1',
          'enabled': false,
          'models': <String>['model-off'],
          'visible_models': <String>['model-off'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
      ],
      'default_model': 'disabled:model-off',
      'default_chat_models': <String>[
        'enabled:model-on',
        'disabled:model-off',
      ],
      'visible_models': <String>['model-on', 'model-off'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    expect(settings.modelList, ['enabled:model-on']);
    expect(settings.defaultModelName, 'enabled:model-on');
    expect(settings.defaultChatModels, ['enabled:model-on']);
  });

  test('setDefaultModelName should also update defaultChatModels priority',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'enabled',
          'displayName': '启用渠道',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://enabled.example/v1',
          'enabled': true,
          'models': <String>['model-a', 'model-b'],
          'visible_models': <String>['model-a', 'model-b'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
      ],
      'default_model': 'enabled:model-a',
      'default_chat_models': <String>['enabled:model-a', 'enabled:model-b'],
      'visible_models': <String>['model-a', 'model-b'],
    };
    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.setDefaultModelName('enabled:model-b');

    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.defaultModelName, 'enabled:model-b');
    expect(
      settings.defaultChatModels,
      <String>['enabled:model-b', 'enabled:model-a'],
    );
  });

  test('updateEnhancedDialogueSettings persists values', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.updateEnhancedDialogueSettings(
      const EnhancedDialogueSettings(
        enabled: true,
        systemPrompt: '增强系统提示词',
        bootstrapUserMessage: '增强任务消息',
        recentRounds: 5,
      ),
    );

    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.enhancedDialogueSettings.enabled, isTrue);
    expect(settings.enhancedDialogueSettings.systemPrompt, '增强系统提示词');
    expect(
      settings.enhancedDialogueSettings.bootstrapUserMessage,
      '增强任务消息',
    );
    expect(settings.enhancedDialogueSettings.recentRounds, 5);
  });

  test('updateCallFlowSettings persists values', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.updateCallFlowSettings(
      const CallFlowSettings(
        mode: CallFlowMode.fast,
        modelTimeoutSeconds: 180,
        toolTimeoutSeconds: 20,
      ),
    );

    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.callFlowSettings.mode, CallFlowMode.fast);
    expect(settings.callFlowSettings.modelTimeoutSeconds, 180);
    expect(settings.callFlowSettings.toolTimeoutSeconds, 20);
  });

  test('setPreferVisionAssistant persists values', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.setPreferVisionAssistant(true);
    var settings = container.read(appSettingsProvider).requireValue;
    expect(settings.preferVisionAssistant, isTrue);

    await notifier.setPreferVisionAssistant(false);
    settings = container.read(appSettingsProvider).requireValue;
    expect(settings.preferVisionAssistant, isFalse);
  });
}
