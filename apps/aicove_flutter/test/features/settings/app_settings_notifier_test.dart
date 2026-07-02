import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api/providers/google_api_mode.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/core/api/providers/zai_compat.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('message format strategy changed should persist as pure UI config',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    final toggled = settings.messageFormatConfig.copyWith(
      enableChunking: !settings.messageFormatConfig.enableChunking,
    );
    await notifier.updateMessageFormatConfig(toggled);

    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .messageFormatConfig
          .toJson(),
      toggled.toJson(),
    );

    await notifier.updateMessageFormatConfig(toggled);
    expect(
      container
          .read(appSettingsProvider)
          .requireValue
          .messageFormatConfig
          .toJson(),
      toggled.toJson(),
    );
  });

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

  test('fresh defaults should include built-in Z.AI provider', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final provider = settings.providers.firstWhere((p) => p.id == 'zai');

    expect(provider.displayName, 'Z.AI');
    expect(provider.apiBaseUrl, kZaiGeneralApiBase);
    expect(provider.enabled, isFalse);
    expect(provider.visibleModels, <String>['glm-5', 'glm-5-turbo', 'glm-4.7']);
    expect(provider.models, containsAll(kZaiDefaultChatModels));
    expect(provider.customConfig['requestFormat'], 'openai');
  });

  test('fresh defaults should include built-in Gemini provider', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final provider = settings.providers.firstWhere((p) => p.id == 'gemini');

    expect(provider.displayName, kGoogleGeminiProviderDisplayName);
    expect(provider.apiBaseUrl, kGeminiDeveloperApiBase);
    expect(provider.enabled, isFalse);
    expect(
      provider.visibleModels,
      <String>[
        'gemini-2.5-flash',
        'gemini-2.5-pro',
        'gemini-2.5-flash-lite',
      ],
    );
    expect(provider.models, containsAll(kGeminiDeveloperDefaultModels));
    expect(provider.customConfig['requestFormat'], 'gemini');
    expect(
        provider.customConfig.containsKey(kGoogleVertexExpressField), isFalse);
  });

  test('legacy store should backfill Z.AI once and allow user deletion',
      () async {
    final legacyStore = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o'],
          'visible_models': <String>['gpt-4o'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'default_model': 'openai:gpt-4o',
      'default_chat_models': <String>['openai:gpt-4o'],
      'visible_models': <String>['gpt-4o'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(legacyStore),
    });

    var container = ProviderContainer();
    addTearDown(() => container.dispose());

    var settings = await container.read(appSettingsProvider.future);
    expect(settings.providers.map((p) => p.id), contains('zai'));

    final prefs = await SharedPreferences.getInstance();
    final firstSaved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    expect(
      (firstSaved['applied_migrations'] as List?)?.cast<String>(),
      contains(kZaiProviderBackfillMigrationId),
    );

    await container.read(appSettingsProvider.notifier).deleteProvider('zai');
    container.dispose();

    container = ProviderContainer();
    settings = await container.read(appSettingsProvider.future);
    expect(settings.providers.map((p) => p.id), isNot(contains('zai')));
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
      customConfig: const <String, dynamic>{'requestFormat': 'openai'},
      allModels: const <String>[],
      visibleModels: const <String>[],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere((p) => p.id == 'openai');
    expect(provider.models, isEmpty);
    expect(provider.visibleModels, isEmpty);
  });

  test('mixed provider import should preserve embedding models and derive tags',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.importCustomModel(
      name: null,
      apiKey: 'dummy-key',
      apiBaseUrl: 'https://example.invalid/v1beta',
      provider: 'gemini',
      customConfig: const <String, dynamic>{'requestFormat': 'gemini'},
      allModels: const <String>['gemini-2.0-flash', 'text-embedding-004'],
      visibleModels: const <String>['gemini-2.0-flash', 'text-embedding-004'],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere(
      (p) => p.apiBaseUrl == 'https://example.invalid/v1beta',
    );
    expect(provider.models, contains('gemini-2.0-flash'));
    expect(provider.models, contains('text-embedding-004'));
    expect(provider.visibleModels, contains('text-embedding-004'));
    expect(provider.capabilities, containsAll(<String>['chat', 'embedding']));
  });

  test('mixed provider update should keep explicit model_types models',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'gemini',
          'displayName': 'Gemini',
          'apiKeys': <String>['dummy-key'],
          'apiBaseUrl': 'https://generativelanguage.googleapis.com/v1beta',
          'enabled': true,
          'models': <String>['gemini-2.0-flash'],
          'visible_models': <String>['gemini-2.0-flash'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'model_types': <String, String>{
        'gemini:custom-model': 'embedding',
      },
      'default_model': 'gemini:gemini-2.0-flash',
      'default_chat_models': <String>['gemini:gemini-2.0-flash'],
      'visible_models': <String>['gemini-2.0-flash'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.updateProviderModels(
      providerId: 'gemini',
      allModels: const <String>['custom-model', 'gemini-2.0-flash'],
      visibleModels: const <String>['custom-model', 'gemini-2.0-flash'],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere((p) => p.id == 'gemini');
    expect(provider.models, <String>['custom-model', 'gemini-2.0-flash']);
    expect(
        provider.visibleModels, <String>['custom-model', 'gemini-2.0-flash']);
    expect(provider.capabilities, containsAll(<String>['chat', 'embedding']));
  });

  test(
      'addCustomModel should append model into provider models and visible list',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>['dummy-key'],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o-mini'],
          'visible_models': <String>['gpt-4o-mini'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'default_model': 'openai:gpt-4o-mini',
      'default_chat_models': <String>['openai:gpt-4o-mini'],
      'visible_models': <String>['gpt-4o-mini'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.addCustomModel(
      providerId: 'openai',
      modelId: 'gpt-5-custom',
      displayName: 'GPT-5 Custom',
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere((p) => p.id == 'openai');
    expect(provider.models, contains('gpt-5-custom'));
    expect(provider.visibleModels, contains('gpt-5-custom'));
    expect(
      settings.getModelDisplayName('openai:gpt-5-custom'),
      'GPT-5 Custom',
    );
  });

  test('legacy Gemini vertexExpress provider should preserve custom baseUrl',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'gemini',
          'displayName': 'Gemini',
          'apiKeys': <String>['vertex-key'],
          'apiBaseUrl':
              'https://aiplatform.googleapis.com/v1/publishers/google',
          'enabled': true,
          'models': <String>['gemini-2.5-pro'],
          'visible_models': <String>['gemini-2.5-pro'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'custom_config': <String, dynamic>{
            'requestFormat': 'gemini',
            'vertexExpress': true,
          },
        },
      ],
      'default_model': 'gemini:gemini-2.5-pro',
      'default_chat_models': <String>['gemini:gemini-2.5-pro'],
      'default_vision_model': 'gemini:gemini-2.5-pro',
      'model_display_names': <String, String>{
        'gemini:gemini-2.5-pro': 'Gemini 2.5 Pro',
      },
      'model_types': <String, String>{
        'gemini:gemini-2.5-pro': 'chat',
      },
      'auto_reply_settings': <String, dynamic>{
        'enabled': false,
        'analyzer_provider': 'gemini',
        'analyzer_model': 'gemini:gemini-2.5-pro',
      },
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final provider = settings.providers.firstWhere((p) => p.id == 'gemini');

    expect(provider.id, 'gemini');
    expect(provider.displayName, 'Gemini');
    expect(
      provider.apiBaseUrl,
      'https://aiplatform.googleapis.com/v1/publishers/google',
    );
    expect(provider.customConfig['requestFormat'], 'gemini');
    expect(provider.customConfig['vertexExpress'], isTrue);
    expect(settings.defaultModelName, 'gemini:gemini-2.5-pro');
    expect(settings.defaultVisionModel, 'gemini:gemini-2.5-pro');
    expect(settings.defaultChatModels, <String>['gemini:gemini-2.5-pro']);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    final savedProviders =
        (saved['providers'] as List).cast<Map<String, dynamic>>();
    final savedProvider = savedProviders.firstWhere(
      (provider) => provider['id'] == 'gemini',
    );
    expect(savedProvider['id'], 'gemini');
    expect(
      savedProvider['apiBaseUrl'],
      'https://aiplatform.googleapis.com/v1/publishers/google',
    );
    expect(
      ((savedProvider['custom_config']
          as Map<String, dynamic>)['vertexExpress']),
      isTrue,
    );
    expect(saved['default_model'], 'gemini:gemini-2.5-pro');
    expect(
      (saved['auto_reply_settings']
          as Map<String, dynamic>)['analyzer_provider'],
      'gemini',
    );
    expect(
      (saved['auto_reply_settings'] as Map<String, dynamic>)['analyzer_model'],
      'gemini:gemini-2.5-pro',
    );
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

  test('importing novelai provider twice should not overwrite old provider',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.importCustomModel(
      name: null,
      apiKey: 'nai-key-1',
      apiBaseUrl: 'https://image.first.example',
      provider: 'novelai',
      displayName: 'NovelAI A',
      customConfig: const <String, dynamic>{'requestFormat': 'novelai'},
      allModels: const <String>['nai-diffusion-4-5-curated'],
      visibleModels: const <String>['nai-diffusion-4-5-curated'],
    );

    await notifier.importCustomModel(
      name: null,
      apiKey: 'nai-key-2',
      apiBaseUrl: 'https://image.second.example',
      provider: 'novelai',
      displayName: 'NovelAI B',
      customConfig: const <String, dynamic>{'requestFormat': 'novelai'},
      allModels: const <String>['nai-diffusion-4-5-curated'],
      visibleModels: const <String>['nai-diffusion-4-5-curated'],
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final providerIds = settings.providers.map((p) => p.id).toList();
    final second = settings.providers.firstWhere((p) => p.id == 'novelai__2');

    expect(providerIds, contains('novelai'));
    expect(providerIds, contains('novelai__2'));
    expect(second.visibleModels, contains('nai-diffusion-4-5-curated'));
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

  test('setModelType stores explicit chat override when inference is non-chat',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'voice',
          'displayName': '语音渠道',
          'apiKeys': <String>['dummy-key'],
          'apiBaseUrl': 'https://voice.example/v1',
          'enabled': true,
          'models': <String>['speech-2.8-hd'],
          'visible_models': <String>['speech-2.8-hd'],
          'hidden_models': <String>[],
          'capabilities': <String>['tts'],
        },
      ],
      'default_model': 'voice:speech-2.8-hd',
      'visible_models': <String>['speech-2.8-hd'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    var settings = await container.read(appSettingsProvider.future);
    const modelRef = 'voice:speech-2.8-hd';
    expect(settings.getModelType(modelRef), ModelType.tts);

    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.setModelType(modelId: modelRef, type: ModelType.chat);

    settings = container.read(appSettingsProvider).requireValue;
    expect(settings.getModelType(modelRef), ModelType.chat);
    expect(settings.modelTypes[modelRef], 'chat');

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    expect(
      (saved['model_types'] as Map<String, dynamic>)[modelRef],
      'chat',
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

  test('history_message_limit should load from persisted store', () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o'],
          'visible_models': <String>['gpt-4o'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'default_model': 'openai:gpt-4o',
      'default_chat_models': <String>['openai:gpt-4o'],
      'visible_models': <String>['gpt-4o'],
      'history_message_limit': 42,
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    expect(settings.historyMessageLimit, 42);
  });

  test('setHistoryMessageLimit should persist values', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.setHistoryMessageLimit(36);

    final settings = container.read(appSettingsProvider).requireValue;
    expect(settings.historyMessageLimit, 36);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    expect(saved['history_message_limit'], 36);
  });

  test(
      'autoReplySettings should migrate reminder toggle from legacy trigger config',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>['test-key'],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o'],
          'visible_models': <String>['gpt-4o'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'default_model': 'openai:gpt-4o',
      'default_chat_models': <String>['openai:gpt-4o'],
      'visible_models': <String>['gpt-4o'],
      'auto_reply_settings': <String, dynamic>{
        'enabled': true,
      },
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
      'aicove.plugins.trigger.config': jsonEncode(
        const <String, dynamic>{
          'enabled': false,
        },
      ),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    expect(settings.autoReplySettings.allowAiSetReminders, isFalse);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    expect(
      (saved['auto_reply_settings']
          as Map<String, dynamic>?)?['allow_ai_set_reminders'],
      isFalse,
    );
  });

  test('updateAutoReplySettings should persist reminder toggle', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);

    await notifier.updateAutoReplySettings(
      settings.autoReplySettings.copyWith(allowAiSetReminders: false),
    );

    final updated = container.read(appSettingsProvider).requireValue;
    expect(updated.autoReplySettings.allowAiSetReminders, isFalse);

    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('aicove.ui_models.v1')!)
        as Map<String, dynamic>;
    expect(
      (saved['auto_reply_settings']
          as Map<String, dynamic>?)?['allow_ai_set_reminders'],
      isFalse,
    );
  });

  test(
      'provider max_context_tokens should survive normalization and override model defaults',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o'],
          'visible_models': <String>['gpt-4o'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'max_context_tokens': 65536,
        },
      ],
      'default_model': 'openai:gpt-4o',
      'default_chat_models': <String>['openai:gpt-4o'],
      'visible_models': <String>['gpt-4o'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final provider = settings.providers.firstWhere((p) => p.id == 'openai');

    expect(provider.maxContextTokens, 65536);
    expect(settings.getMaxContextTokens('openai:gpt-4o'), 65536);
  });

  test('updateProviderParams should persist provider max_context_tokens',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'openai',
          'displayName': 'OpenAI',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'models': <String>['gpt-4o'],
          'visible_models': <String>['gpt-4o'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
        },
      ],
      'default_model': 'openai:gpt-4o',
      'default_chat_models': <String>['openai:gpt-4o'],
      'visible_models': <String>['gpt-4o'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(appSettingsProvider.future);
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.updateProviderParams(
      providerId: 'openai',
      maxContextTokens: 65536,
    );

    final settings = container.read(appSettingsProvider).requireValue;
    final provider = settings.providers.firstWhere((p) => p.id == 'openai');
    expect(provider.maxContextTokens, 65536);
    expect(settings.getMaxContextTokens('openai:gpt-4o'), 65536);
  });

  test('loading legacy provider model_type should scrub old field', () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'legacy',
          'displayName': '旧渠道',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://legacy.example/v1',
          'enabled': true,
          'models': <String>['text-embedding-3-small'],
          'visible_models': <String>['text-embedding-3-small'],
          'hidden_models': <String>[],
          'capabilities': <String>['chat'],
          'model_type': 'chat',
        },
      ],
      'model_types': <String, String>{
        'legacy:text-embedding-3-small': 'embedding',
      },
      'default_model': 'legacy:text-embedding-3-small',
      'visible_models': <String>['text-embedding-3-small'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);
    final provider = settings.providers.firstWhere((p) => p.id == 'legacy');
    expect(provider.capabilities, contains('embedding'));
    expect(provider.capabilities, isNot(contains('chat')));

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('aicove.ui_models.v1');
    expect(saved, isNotNull);
    expect(saved, isNot(contains('"model_type"')));
  });

  test('tts available models should exclude hidden voice-tagged models',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'voice',
          'displayName': '语音渠道',
          'apiKeys': <String>[],
          'apiBaseUrl': 'https://voice.example/v1',
          'enabled': true,
          'models': <String>['voice-public', 'voice-hidden', 'chat-model'],
          'visible_models': <String>['voice-public', 'chat-model'],
          'hidden_models': <String>['voice-hidden'],
          'capabilities': <String>['chat', 'tts'],
        },
      ],
      'model_types': <String, String>{
        'voice:voice-public': 'tts',
        'voice:voice-hidden': 'tts',
        'voice:chat-model': 'chat',
      },
      'default_model': 'voice:chat-model',
      'default_chat_models': <String>['voice:chat-model'],
      'visible_models': <String>['voice-public', 'chat-model'],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);

    expect(
      settings.getProviderVisibleModelsByType(
        'voice',
        type: ModelType.tts,
      ),
      <String>['voice-public'],
    );
  });

  test('minimax speech models should infer as tts without explicit model_types',
      () async {
    final store = <String, dynamic>{
      'providers': [
        {
          'id': 'minimax',
          'displayName': 'MiniMax',
          'apiKeys': <String>['dummy-key'],
          'apiBaseUrl': 'https://api.minimaxi.com',
          'enabled': true,
          'models': <String>[
            'speech-2.8-hd',
            'speech-02-turbo',
            'abab7-chat-preview',
          ],
          'visible_models': <String>[
            'speech-2.8-hd',
            'speech-02-turbo',
            'abab7-chat-preview',
          ],
          'hidden_models': <String>[],
          'capabilities': <String>['chat', 'tts'],
          'custom_config': <String, dynamic>{'requestFormat': 'openai_tts'},
        },
      ],
      'default_model': 'minimax:abab7-chat-preview',
      'default_chat_models': <String>['minimax:abab7-chat-preview'],
      'visible_models': <String>[
        'speech-2.8-hd',
        'speech-02-turbo',
        'abab7-chat-preview',
      ],
    };

    SharedPreferences.setMockInitialValues(<String, Object>{
      'aicove.ui_models.v1': jsonEncode(store),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(appSettingsProvider.future);

    expect(
      settings.getProviderVisibleModelsByType(
        'minimax',
        type: ModelType.tts,
      ),
      unorderedEquals(<String>['speech-2.8-hd', 'speech-02-turbo']),
    );
    expect(
      settings.getModelType('minimax:speech-2.8-hd'),
      ModelType.tts,
    );
    expect(
      settings.getModelType('minimax:speech-02-turbo'),
      ModelType.tts,
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

  test('call flow settings should migrate legacy stable mode to auto', () {
    final settings = CallFlowSettings.fromJson(<String, dynamic>{
      'mode': 'stable',
    });

    expect(settings.mode, CallFlowMode.auto);
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
