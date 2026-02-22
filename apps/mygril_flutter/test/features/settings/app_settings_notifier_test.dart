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
}
