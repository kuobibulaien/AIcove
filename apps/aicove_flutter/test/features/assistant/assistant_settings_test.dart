// ADR0073 T3b: the assistant changes only whitelisted settings, each change
// is undoable, and switching to another channel's model is a major call.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_settings_tools.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assistant_onboarding_test.dart' show deepSeek, settingsWith;

class _Settings extends AppSettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<AppSettings> readStored() async => state.requireValue;

  AppSettings get _now => state.value!;

  @override
  Future<void> setDarkModeAndSystemTheme({
    required bool isDark,
    required bool useSystem,
  }) async => state = AsyncValue.data(
    _now.copyWith(isDarkMode: isDark, useSystemTheme: useSystem),
  );

  // AppSettings.copyWith cannot clear a field; an empty name reads as none.
  @override
  Future<void> setUserName(String? name) async =>
      state = AsyncValue.data(_now.copyWith(userName: name ?? ''));

  @override
  Future<void> updateAutoReplySettings(AutoReplySettings settings) async =>
      state = AsyncValue.data(_now.copyWith(autoReplySettings: settings));

  @override
  Future<void> setDefaultChatModels(List<String> models) async =>
      state = AsyncValue.data(
        _now.copyWith(
          defaultChatModels: models,
          defaultModelName: models.first,
        ),
      );
}

ProviderAuth _other({bool withKey = true}) => ProviderAuth(
  id: 'openrouter',
  displayName: 'OpenRouter',
  apiKeys: withKey ? const ['sk-or-secret'] : const [],
  apiBaseUrl: 'https://openrouter.ai/api/v1',
  enabled: true,
  models: const ['gpt-x'],
  visibleModels: const ['gpt-x'],
);

void main() {
  late Directory dir;
  late ProviderContainer container;
  late AssistantSettingsTools tools;
  late FileChangeJournal journal;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('assistant_settings_');
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(
          () => _Settings(
            settingsWith([
              deepSeek(keys: const ['sk-deepseek-secret']),
              _other(),
            ], 'deepseek:deepseek-flash'),
          ),
        ),
      ],
    );
    await container.read(appSettingsProvider.future);
    Future<AppSettings> load() => container.read(appSettingsProvider.future);
    AppSettingsNotifier notifier() =>
        container.read(appSettingsProvider.notifier);
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: {
        assistantSettingChangeKind: AssistantSettingApplier(
          notifier: notifier,
        ),
      },
    );
    tools = AssistantSettingsTools(
      current: () => container.read(appSettingsProvider).valueOrNull,
      load: load,
      notifier: notifier,
      journal: journal,
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
            (await tools
                .tools()
                .singleWhere((t) => t.name == name)
                .handler(args))!,
          )
          as Map<String, dynamic>;

  AppSettings now() => container.read(appSettingsProvider).value!;

  test(
    'a whitelisted change applies and undoes; a later edit blocks undo',
    () async {
      final done = await run(AssistantSettingsTools.setTool, {
        'key': 'appearance.theme',
        'value': 'dark',
      });
      expect(done['ok'], isTrue);
      expect(now().isDarkMode, isTrue);
      expect(now().useSystemTheme, isFalse);

      await journal.undo((await journal.recent()).first.id);
      expect(now().useSystemTheme, isTrue);

      await run(AssistantSettingsTools.setTool, {
        'key': 'appearance.theme',
        'value': 'light',
      });
      final change = (await journal.recent()).first.id;
      await container
          .read(appSettingsProvider.notifier)
          .setDarkModeAndSystemTheme(isDark: true, useSystem: false);
      await expectLater(journal.undo(change), throwsStateError);
    },
  );

  test('unknown keys and bad values change nothing', () async {
    final unknown = await run(AssistantSettingsTools.setTool, {
      'key': 'providers.deepseek.api_key',
      'value': 'x',
    });
    final badValue = await run(AssistantSettingsTools.setTool, {
      'key': 'appearance.theme',
      'value': 'purple',
    });
    final outOfRange = await run(AssistantSettingsTools.setTool, {
      'key': 'appearance.text_scale',
      'value': 3,
    });
    expect(unknown['error'], 'invalid');
    expect(badValue['error'], 'invalid');
    expect(outOfRange['error'], 'invalid');
    expect(await journal.recent(), isEmpty);
  });

  test(
    'another channel\'s model is major; one without a key is refused',
    () async {
      AssistantRisk? risk(String model) => tools.riskOf(
        AssistantSettingsTools.setTool,
        {'key': 'model.default_chat', 'value': model},
      );
      expect(risk('deepseek:deepseek-v4-pro'), AssistantRisk.reversible);
      expect(risk('openrouter:gpt-x'), AssistantRisk.major);
      expect(
        tools.riskOf(AssistantSettingsTools.getTool, const {}),
        AssistantRisk.readOnly,
      );

      final missing = await run(AssistantSettingsTools.setTool, {
        'key': 'model.default_chat',
        'value': 'deepseek:nope',
      });
      expect(missing['error'], 'invalid');

      await run(AssistantSettingsTools.setTool, {
        'key': 'model.default_chat',
        'value': 'deepseek:deepseek-v4-pro',
      });
      expect(now().defaultChatModels.first, 'deepseek:deepseek-v4-pro');
    },
  );

  test('settings and channels are read without any key', () async {
    final read = await run(AssistantSettingsTools.getTool, const {});
    expect(
      [for (final s in read['settings'] as List) (s as Map)['key']],
      [for (final s in kAssistantSettings) s.key],
    );

    final cards = AssistantCardTools(
      settings: () => container.read(appSettingsProvider.future),
      cards: () => container.read(assistantCardsProvider.notifier),
      roleExists: (id) async => id == 'role_li',
      presetExists: (_) async => false,
    );
    Future<Map<String, dynamic>> card(
      String name,
      Map<String, dynamic> args,
    ) async =>
        jsonDecode(
              (await cards
                  .tools()
                  .singleWhere((t) => t.name == name)
                  .handler(args))!,
            )
            as Map<String, dynamic>;

    final providers = await card(AssistantCardTools.listProviders, const {});
    expect(jsonEncode(providers), isNot(contains('secret')));
    expect((providers['providers'] as List).first['has_key'], isTrue);

    await card(AssistantCardTools.requestKey, {'provider_id': 'openrouter'});
    final hidden = await card(AssistantCardTools.openPage, {
      'target': 'role_edit',
      'id': 'role_secret',
    });
    await card(AssistantCardTools.openPage, {
      'target': 'role_edit',
      'id': 'role_li',
    });
    expect(hidden['error'], 'not_found');
    final shown = container.read(assistantCardsProvider);
    expect(
      shown.whereType<AssistantKeyRequest>().single.providerId,
      'openrouter',
    );
    expect(shown.whereType<AssistantPageLink>().single.targetId, 'role_li');
  });

  test('undoing a default model brings the whole ordered list back', () async {
    await container.read(appSettingsProvider.notifier).setDefaultChatModels(
      const [
        'deepseek:deepseek-flash',
        'openrouter:gpt-x',
        'deepseek:deepseek-v4-pro',
      ],
    );
    await run(AssistantSettingsTools.setTool, {
      'key': 'model.default_chat',
      'value': 'deepseek:deepseek-v4-pro',
    });
    expect(now().defaultChatModels, [
      'deepseek:deepseek-v4-pro',
      'deepseek:deepseek-flash',
      'openrouter:gpt-x',
    ]);
    await journal.undo((await journal.recent()).first.id);
    expect(now().defaultChatModels, [
      'deepseek:deepseek-flash',
      'openrouter:gpt-x',
      'deepseek:deepseek-v4-pro',
    ]);
  });

  test('a default model is saved, recorded and undone in one form', () async {
    await container.read(appSettingsProvider.notifier).setDefaultChatModels(
      const ['deepseek:deepseek-flash', 'deepseek:deepseek-v4-pro'],
    );
    final result = await run(AssistantSettingsTools.setTool, {
      'key': 'model.default_chat',
      'value': 'deepseek: deepseek-v4-pro',
    });
    expect(result['ok'], isTrue);
    expect(now().defaultChatModels, [
      'deepseek:deepseek-v4-pro',
      'deepseek:deepseek-flash',
    ]);
    await journal.undo((await journal.recent()).first.id);
    expect(now().defaultChatModels, [
      'deepseek:deepseek-flash',
      'deepseek:deepseek-v4-pro',
    ]);
  });

  test('a name can be cleared and the clearing undone', () async {
    await run(AssistantSettingsTools.setTool, {
      'key': 'profile.user_name',
      'value': ' 小林 ',
    });
    expect(now().userName, '小林');
    final cleared = await run(AssistantSettingsTools.setTool, {
      'key': 'profile.user_name',
      'value': '',
    });
    expect(cleared['ok'], isTrue);
    expect(now().userName, isEmpty);
    await journal.undo((await journal.recent()).first.id);
    expect(now().userName, '小林');
    final wrongType = await run(AssistantSettingsTools.setTool, {
      'key': 'profile.user_name',
      'value': 3,
    });
    expect(wrongType['error'], 'invalid');
  });

  test('the settings page of the library lists every whitelisted key', () {
    final doc = assistantSettingsDoc();
    for (final setting in kAssistantSettings) {
      expect(doc, contains('`${setting.key}`'));
    }
  });

  test('nested settings change one field and undo it', () async {
    final before = now().autoReplySettings;
    final done = await run(AssistantSettingsTools.setTool, {
      'key': 'auto_reply.daily_limit',
      'value': 5,
    });
    expect(done['ok'], isTrue);
    expect(now().autoReplySettings.dailyLimit, 5);
    expect(now().autoReplySettings.quietHoursStart, before.quietHoursStart);

    final bad = await run(AssistantSettingsTools.setTool, {
      'key': 'auto_reply.quiet_start',
      'value': '25:00',
    });
    expect(bad['ok'], isNot(isTrue));
    expect(now().autoReplySettings.quietHoursStart, before.quietHoursStart);

    await journal.undo((await journal.recent()).first.id);
    expect(now().autoReplySettings.dailyLimit, before.dailyLimit);
  });
}
