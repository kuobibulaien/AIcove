import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_rename.dart';
import 'package:aicove_flutter/src/features/chat/data/preset_characters_loader.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'a fresh install gets the pinned assistant next to the preset',
    () async {
      final list = await container().read(conversationsProvider.future);

      final assistant = list.firstWhere((c) => c.id == kAicoveAssistantId);
      expect(assistant.isPinned, isTrue);
      expect(assistant.displayName, 'AIcove酱');
      expect(assistant.personaPrompt, contains('AIcove'));
      expect(list.map((c) => c.id), contains('preset_nahida'));
    },
  );

  test(
    'a deleted assistant stays deleted until restored from settings',
    () async {
      final first = container();
      await first.read(conversationsProvider.future);
      // Same trash write as deleting the contact in the app.
      await first
          .read(conversationRepositoryProvider)
          .softDelete(kAicoveAssistantId, 1, 2);

      final second = container();
      final relaunched = await second.read(conversationsProvider.future);
      expect(relaunched.map((c) => c.id), isNot(contains(kAicoveAssistantId)));

      final restored = await second
          .read(conversationsProvider.notifier)
          .restoreAssistant();
      expect(restored?.id, kAicoveAssistantId);
      final third = container();
      final afterRestore = await third.read(conversationsProvider.future);
      expect(afterRestore.map((c) => c.id), contains(kAicoveAssistantId));
    },
  );

  test('a changed preset overwrites AIcove酱 even after user edits', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == kAicoveAssistantId);
    SharedPreferences.setMockInitialValues({
      'aicove_assistant_seeded_v1': true,
      'aicove_assistant_preset_fingerprint': 'an older build',
    });
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(
          title: '我的小助手',
          displayName: '我的小助手',
          personaPrompt: '我自己改过的设定',
          avatarUrl: 'my_avatar.png',
          isMuted: true,
        ),
      ),
    );

    await container().read(conversationsProvider.future);
    final stored = (await container().read(conversationsProvider.future))
        .firstWhere((c) => c.id == kAicoveAssistantId);
    expect(stored.displayName, preset.displayName);
    expect(stored.title, preset.title);
    expect(stored.personaPrompt, preset.personaPrompt);
    expect(stored.avatarUrl, preset.avatarUrl);
    expect(stored.isMuted, isTrue);
  });

  test('an unchanged preset leaves later user edits alone', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == kAicoveAssistantId);
    SharedPreferences.setMockInitialValues({
      'aicove_assistant_seeded_v1': true,
      'aicove_assistant_preset_fingerprint': assistantPresetFingerprint(
        preset,
      ),
    });
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(personaPrompt: '我自己改过的设定'),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    expect(
      list.firstWhere((c) => c.id == kAicoveAssistantId).personaPrompt,
      '我自己改过的设定',
    );
  });

  test('an untouched legacy Nahida persona updates to the WeChat-style prompt and keeps drawing bindings', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == 'preset_nahida');
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: legacyNahidaUserPrompt,
            drawingPresetId: 'drawing_custom',
          ),
        ),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    final nahida = list.firstWhere((c) => c.id == 'preset_nahida');
    final parts = PersonaPromptCodec.parse(nahida.personaPrompt);
    expect(parts.userPrompt, contains('## 输出与微信聊天规范'));
    expect(parts.userPrompt, contains('## 对话示例'));
    expect(parts.drawingPresetId, 'drawing_custom');
  });

  test('a user-edited Nahida persona is left untouched', () async {
    final preset = (await PresetCharactersLoader.load())
        .firstWhere((c) => c.id == 'preset_nahida');
    await database.into(database.conversations).insert(
      ConversationConverter.toCompanion(
        preset.copyWith(personaPrompt: '我自己改过的纳西妲设定'),
      ),
    );

    final list = await container().read(conversationsProvider.future);
    final nahida = list.firstWhere((c) => c.id == 'preset_nahida');
    expect(nahida.personaPrompt, '我自己改过的纳西妲设定');
  });
}
