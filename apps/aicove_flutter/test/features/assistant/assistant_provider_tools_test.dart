// ADR0073 full access, batch P2: the assistant manages channels without
// ever seeing a key; changes undo, address changes and deletes ask the user.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_provider_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assistant_onboarding_test.dart' show deepSeek, settingsWith;

class _Settings extends AppSettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;
  final deleted = <String>[];

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<AppSettings> readStored() async => state.requireValue;

  AppSettings get _now => state.value!;

  void _edit(String id, ProviderAuth Function(ProviderAuth p) change) =>
      state = AsyncValue.data(
        _now.copyWith(
          providers: [
            for (final p in _now.providers) p.id == id ? change(p) : p,
          ],
        ),
      );

  @override
  Future<void> editProvider({
    required String providerId,
    String? displayName,
    String? apiBaseUrl,
    List<String>? apiKeys,
    List<String>? capabilities,
    Map<String, dynamic>? customConfig,
  }) async => _edit(
    providerId,
    (p) => p.copyWith(displayName: displayName, apiBaseUrl: apiBaseUrl),
  );

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async =>
      _edit(providerId, (p) => p.copyWith(enabled: enabled));

  @override
  Future<void> updateProviderModels({
    required String providerId,
    required List<String> allModels,
    List<String>? visibleModels,
    List<String>? hiddenModels,
  }) async => _edit(
    providerId,
    (p) => p.copyWith(
      models: allModels,
      visibleModels: visibleModels,
      hiddenModels: hiddenModels,
    ),
  );

  @override
  Future<void> deleteProvider(String providerId) async {
    deleted.add(providerId);
    state = AsyncValue.data(
      _now.copyWith(
        providers: [
          for (final p in _now.providers)
            if (p.id != providerId) p,
        ],
      ),
    );
  }
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late AssistantProviderTools tools;
  late FileChangeJournal journal;
  late _Settings settings;
  var failTest = true;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('assistant_providers_');
    settings = _Settings(
      settingsWith([
        deepSeek(keys: const ['sk-deepseek-secret']),
      ], 'deepseek:deepseek-flash'),
    );
    container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(() => settings)],
    );
    await container.read(appSettingsProvider.future);
    Future<AppSettings> load() => container.read(appSettingsProvider.future);
    AppSettingsNotifier notifier() =>
        container.read(appSettingsProvider.notifier);
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {
        assistantProviderChangeKind: AssistantProviderApplier(
          notifier: notifier,
        ),
      },
    );
    tools = AssistantProviderTools(
      current: () => container.read(appSettingsProvider).valueOrNull,
      load: load,
      notifier: notifier,
      journal: journal,
      cards: () => container.read(assistantCardsProvider.notifier),
      primaryKey: (p) => p.apiKeys.firstOrNull ?? '',
      testModel: (p, model) async =>
          failTest ? throw Exception('HTTP 401 invalid key ${p.apiKeys.first}') : 'echo ${p.apiKeys.first}',
    );
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> run(
    String name,
    Map<String, dynamic> args,
  ) async =>
      jsonDecode(
            (await tools.tools().singleWhere((t) => t.name == name).handler(
              args,
            ))!,
          )
          as Map<String, dynamic>;

  ProviderAuth deepseekNow() =>
      container.read(appSettingsProvider).value!.getProvider('deepseek')!;

  test('renaming and choosing models undo; the key is untouched', () async {
    await run(AssistantProviderTools.updateProvider, {
      'provider_id': 'deepseek',
      'display_name': '深度求索',
    });
    await run(AssistantProviderTools.setModels, {
      'provider_id': 'deepseek',
      'visible': ['deepseek-flash', 'deepseek-new'],
    });
    expect(deepseekNow().displayName, '深度求索');
    expect(deepseekNow().models, contains('deepseek-new'));
    expect(deepseekNow().hiddenModels, ['deepseek-v4-pro']);

    for (final entry in await journal.recent()) {
      await journal.undo(entry.id);
    }
    expect(deepseekNow().displayName, 'DeepSeek');
    expect(deepseekNow().models, ['deepseek-flash', 'deepseek-v4-pro']);
    expect(deepseekNow().apiKeys, ['sk-deepseek-secret']);
    expect(
      await File('${dir.path}/journal.json').readAsString(),
      isNot(contains('sk-deepseek-secret')),
    );
  });

  test('address changes and deletes ask the user; disabling is reviewed', () {
    expect(
      tools.riskOf(AssistantProviderTools.updateProvider, {
        'provider_id': 'deepseek',
        'api_base_url': 'https://evil.example/v1',
      }),
      AssistantRisk.major,
    );
    expect(
      tools.riskOf(AssistantProviderTools.deleteProvider, {
        'provider_id': 'deepseek',
      }),
      AssistantRisk.major,
    );
    expect(
      tools.riskOf(AssistantProviderTools.updateProvider, {
        'provider_id': 'deepseek',
        'enabled': false,
      }),
      AssistantRisk.review,
    );
    expect(
      tools
          .describe(AssistantProviderTools.deleteProvider, {
            'provider_id': 'deepseek',
          })
          .detail,
      contains('默认聊天模型'),
    );
  });

  test('a new channel is only a card until the user pastes a key', () async {
    final result = await run(AssistantProviderTools.addProvider, {
      'format': 'openai',
      'api_base_url': 'https://openrouter.ai/api/v1',
      'display_name': 'OpenRouter',
    });
    expect(result['ok'], isTrue);
    final card = container.read(assistantCardsProvider).single;
    expect(card, isA<AssistantKeyRequest>());
    expect((card as AssistantKeyRequest).draft?.baseUrl,
        'https://openrouter.ai/api/v1');
    expect(container.read(appSettingsProvider).value!.providers, hasLength(1));
  });

  test('a failing test hides the key from the model', () async {
    final result = await run(AssistantProviderTools.testProvider, {
      'provider_id': 'deepseek',
    });
    expect(result['ok'], isFalse);
    expect(jsonEncode(result), isNot(contains('sk-deepseek-secret')));
  });

  test('delete removes the channel', () async {
    await run(AssistantProviderTools.deleteProvider, {
      'provider_id': 'deepseek',
    });
    expect(settings.deleted, ['deepseek']);
  });

  test('a successful test echoing the key is scrubbed too', () async {
    failTest = false;
    final result = await run(AssistantProviderTools.testProvider, {
      'provider_id': 'deepseek',
    });
    failTest = true;
    expect(result['ok'], isTrue);
    expect(jsonEncode(result), isNot(contains('sk-deepseek-secret')));
  });

  test('undo restores only what the call changed', () async {
    await run(AssistantProviderTools.updateProvider, {
      'provider_id': 'deepseek',
      'display_name': '深度求索',
    });
    // The user edits the address by hand afterwards.
    await container
        .read(appSettingsProvider.notifier)
        .editProvider(providerId: 'deepseek', apiBaseUrl: 'https://mine/v1');
    await journal.undo((await journal.recent()).first.id);
    expect(deepseekNow().displayName, 'DeepSeek');
    expect(deepseekNow().apiBaseUrl, 'https://mine/v1');
  });

  test('a short or quoted key echoed back is scrubbed', () async {
    for (final key in ['abc', 'ab"c\\d']) {
      await container
          .read(appSettingsProvider.notifier)
          .editProvider(providerId: 'deepseek', apiKeys: [key]);
      settings.state = AsyncValue.data(
        settings.state.value!.copyWith(
          providers: [deepseekNow().copyWith(apiKeys: [key])],
        ),
      );
      failTest = false;
      final result = await run(AssistantProviderTools.testProvider, {
        'provider_id': 'deepseek',
      });
      failTest = true;
      expect('${result['reply']}', isNot(contains(key)), reason: key);
    }
  });
}
