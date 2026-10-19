import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_onboarding_controller.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppSettings settingsWith(List<ProviderAuth> providers, String defaultModel) =>
    AppSettings(
      ttsEnabled: true,
      defaultModelName: defaultModel,
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
      providers: providers,
      modelProviderMap: const <String, String>{},
      backendApiKey: '',
      messageChunkingEnabled: false,
      messageFormatConfig: const MessageFormatConfig(
        enableChunking: false,
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
      defaultChatModels: <String>[defaultModel],
    );

ProviderAuth deepSeek({List<String> keys = const [], bool enabled = true}) =>
    ProviderAuth(
      id: 'deepseek',
      displayName: 'DeepSeek',
      apiKeys: keys,
      apiBaseUrl: 'https://api.deepseek.com/v1',
      enabled: enabled,
      models: const ['deepseek-flash', 'deepseek-v4-pro'],
      visibleModels: const ['deepseek-flash', 'deepseek-v4-pro'],
    );

class FakeSettings extends AppSettingsNotifier {
  FakeSettings(this.initial, {this.testError});

  final AppSettings initial;
  final Object? testError;
  final testedKeys = <String>[];
  final savedKeys = <List<String>>[];
  final enabledProviders = <String>[];
  List<String>? defaultChatModels;

  @override
  Future<AppSettings> build() async => initial;

  AppSettings get _now => state.value!;

  void _replaceProvider(ProviderAuth Function(ProviderAuth) fn) {
    state = AsyncValue.data(
      _now.copyWith(
        providers: [
          for (final p in _now.providers) p.id == 'deepseek' ? fn(p) : p,
        ],
      ),
    );
  }

  @override
  Future<String> testModel({
    required String providerId,
    required String apiKey,
    required String apiBaseUrl,
    required String modelId,
    Map<String, dynamic>? customConfig,
    ModelType modelType = ModelType.chat,
  }) async {
    testedKeys.add(apiKey);
    final error = testError;
    if (error != null) throw error;
    return 'ok';
  }

  @override
  Future<void> editProvider({
    required String providerId,
    String? displayName,
    String? apiBaseUrl,
    List<String>? apiKeys,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
  }) async {
    savedKeys.add(apiKeys ?? const []);
    _replaceProvider((p) => p.copyWith(apiKeys: apiKeys));
  }

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    enabledProviders.add(providerId);
    _replaceProvider((p) => p.copyWith(enabled: enabled));
  }

  @override
  Future<void> setDefaultChatModels(List<String> models) async {
    defaultChatModels = models;
    state = AsyncValue.data(
      _now.copyWith(defaultModelName: models.first, defaultChatModels: models),
    );
  }
}

class EmptyConversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

ProviderContainer containerFor(FakeSettings settings) => ProviderContainer(
  overrides: [
    appSettingsProvider.overrideWith(() => settings),
    conversationsProvider.overrideWith(EmptyConversations.new),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('classifyKeyCheckError', () {
    test('maps HTTP status and transport errors to script reasons', () {
      Exception wrapped(String inner) => Exception('模型测试失败: Exception: $inner');
      expect(
        classifyKeyCheckError(wrapped('HTTP 401: {"error":"auth"}')),
        KeyCheckFailure.invalidKey,
      );
      expect(
        classifyKeyCheckError(wrapped('HTTP 402: Insufficient Balance')),
        KeyCheckFailure.insufficientBalance,
      );
      expect(
        classifyKeyCheckError(TimeoutException('slow')),
        KeyCheckFailure.network,
      );
      expect(
        classifyKeyCheckError(const SocketException('no route')),
        KeyCheckFailure.network,
      );
      expect(
        classifyKeyCheckError(wrapped('HTTP 404: model not found')),
        KeyCheckFailure.other,
      );
    });
  });

  group('hasUsableChatModel', () {
    test('needs an enabled chat provider with a key behind the default', () {
      expect(
        hasUsableChatModel(
          settingsWith([deepSeek()], 'deepseek:deepseek-flash'),
        ),
        isFalse,
      );
      expect(
        hasUsableChatModel(
          settingsWith([
            deepSeek(keys: ['sk-1'], enabled: false),
          ], 'deepseek:deepseek-flash'),
        ),
        isFalse,
      );
      expect(
        hasUsableChatModel(
          settingsWith([
            deepSeek(keys: ['sk-1']),
          ], 'deepseek:deepseek-flash'),
        ),
        isTrue,
      );
    });
  });

  test('state survives a restart through local preferences', () async {
    final first = containerFor(
      FakeSettings(settingsWith([deepSeek()], 'deepseek:deepseek-flash')),
    );
    await first.read(assistantOnboardingProvider.future);
    await first
        .read(assistantOnboardingProvider.notifier)
        .chooseExperience(experienced: true);
    first.dispose();

    final second = containerFor(
      FakeSettings(settingsWith([deepSeek()], 'deepseek:deepseek-flash')),
    );
    addTearDown(second.dispose);
    final state = await second.read(assistantOnboardingProvider.future);
    expect(state.step, OnboardingStep.chooseProvider);
    expect(state.experienced, isTrue);
    expect(state.outcome, OnboardingOutcome.pending);
  });

  test('a rejected key is reported and never saved', () async {
    final settings = FakeSettings(
      settingsWith([deepSeek()], 'deepseek:deepseek-flash'),
      testError: Exception('模型测试失败: Exception: HTTP 401: invalid'),
    );
    final container = containerFor(settings);
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(assistantOnboardingProvider.future);

    final failure = await container
        .read(assistantOnboardingProvider.notifier)
        .submitRecommendedKey('  sk-wrong  ');

    expect(failure, KeyCheckFailure.invalidKey);
    expect(settings.testedKeys, ['sk-wrong']);
    expect(settings.savedKeys, isEmpty);
    expect(settings.defaultChatModels, isNull);
    expect(container.read(assistantScriptActiveProvider), isTrue);
  });

  test('a working key is saved, made default and ends the script', () async {
    final settings = FakeSettings(
      settingsWith([deepSeek(enabled: false)], 'gemini:other'),
    );
    final container = containerFor(settings);
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(assistantOnboardingProvider.future);
    expect(container.read(assistantScriptActiveProvider), isTrue);

    final failure = await container
        .read(assistantOnboardingProvider.notifier)
        .submitRecommendedKey('sk-good');

    expect(failure, isNull);
    expect(settings.savedKeys, [
      ['sk-good'],
    ]);
    expect(settings.enabledProviders, ['deepseek']);
    expect(settings.defaultChatModels?.first, 'deepseek:deepseek-flash');
    final state = container.read(assistantOnboardingProvider).value!;
    expect(state.outcome, OnboardingOutcome.completed);
    expect(container.read(assistantScriptActiveProvider), isFalse);
  });

  test('a tested provider is enabled before it becomes the default', () async {
    final settings = FakeSettings(
      settingsWith([
        deepSeek(keys: ['sk-1'], enabled: false),
      ], 'gemini:other'),
    );
    final container = containerFor(settings);
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(assistantOnboardingProvider.future);

    final failure = await container
        .read(assistantOnboardingProvider.notifier)
        .useProviderModel(providerId: 'deepseek', modelId: 'deepseek-flash');

    expect(failure, isNull);
    expect(settings.enabledProviders, ['deepseek']);
    expect(
      hasUsableChatModel(container.read(appSettingsProvider).value!),
      isTrue,
    );
  });

  test('skipping everything hides the script even without a model', () async {
    final container = containerFor(
      FakeSettings(settingsWith([deepSeek()], 'deepseek:deepseek-flash')),
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await container.read(assistantOnboardingProvider.future);

    await container.read(assistantOnboardingProvider.notifier).skipAll();

    expect(
      container.read(assistantOnboardingProvider).value!.outcome,
      OnboardingOutcome.skipped,
    );
    expect(container.read(assistantScriptActiveProvider), isFalse);
  });
}
