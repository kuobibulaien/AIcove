import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_rename.dart';
import 'package:aicove_flutter/src/features/chat/data/preset_characters_loader.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:drift/native.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/core/database/repositories/conversation_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
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

  test('Mangaka is seeded once with a persisted greeting', () async {
    final c = container();
    final list = await c.read(conversationsProvider.future);
    final role = list.firstWhere((r) => r.id == kMangakaPresetId);
    expect(role.agentMode, RoleAgentMode.tool);
    expect(role.chatDisplayStyle, ChatDisplayStyle.document);
    expect(role.enabledPlugins, ['memory', 'time_awareness', 'image']);
    expect(role.personaPrompt, isNotEmpty);
    final repo = c.read(messageRepositoryProvider);
    final greeting = await repo.getByConversation(kMangakaPresetId);
    expect(greeting, hasLength(1));
    expect(greeting.single.id, 'msg_greeting_$kMangakaPresetId');
    expect(
      greeting.single.content,
      await PresetCharactersLoader.firstMessageFor(kMangakaPresetId),
    );
    expect(greeting.single.rawPayload, isNotNull);
    final projected = c
        .read(chatFrontendMessageProjectionServiceProvider)
        .projectMessage(MessageConverter.fromDb(greeting.single));
    expect(projected, hasLength(1));
    expect(projected.single.content, greeting.single.content);
    await container().read(conversationsProvider.future);
    expect(await repo.getByConversation(kMangakaPresetId), hasLength(1));
  });

  test('Mangaka tombstone is respected even without a seed flag', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final c = container();
    final repo = c.read(conversationRepositoryProvider);
    await repo.upsert(ConversationConverter.toCompanion(preset));
    await repo.softDelete(kMangakaPresetId, 1, 2);
    final list = await c.read(conversationsProvider.future);
    expect(list.any((r) => r.id == kMangakaPresetId), isFalse);
    expect((await repo.getById(kMangakaPresetId))!.deletedAt, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isTrue,
    );
  });

  test('failed Mangaka storage does not mark seeded and retries', () async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationRepositoryProvider.overrideWithValue(
          _FailMangakaOnce(database),
        ),
      ],
    );
    addTearDown(c.dispose);
    final first = await c.read(conversationsProvider.future);
    expect(first.any((r) => r.id == kMangakaPresetId), isFalse);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isNot(true),
    );
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      isEmpty,
    );
    c.invalidate(conversationsProvider);
    final retry = await c.read(conversationsProvider.future);
    expect(retry.any((r) => r.id == kMangakaPresetId), isTrue);
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      hasLength(1),
    );
  });

  test('greeting failure rolls back role and can retry', () async {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        messageRepositoryProvider.overrideWithValue(
          _FailGreetingOnce(database),
        ),
      ],
    );
    addTearDown(c.dispose);
    final first = await c.read(conversationsProvider.future);
    expect(first.any((r) => r.id == kMangakaPresetId), isFalse);
    expect(
      await c.read(conversationRepositoryProvider).getById(kMangakaPresetId),
      isNull,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'preset_mangaka_seeded_v1',
      ),
      isNot(true),
    );
    c.invalidate(conversationsProvider);
    expect(
      (await c.read(
        conversationsProvider.future,
      )).any((r) => r.id == kMangakaPresetId),
      isTrue,
    );
    expect(
      await c
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      hasLength(1),
    );
  });

  test('purged Mangaka is not seeded again', () async {
    SharedPreferences.setMockInitialValues({'preset_mangaka_seeded_v1': true});
    expect(
      (await container().read(
        conversationsProvider.future,
      )).any((r) => r.id == kMangakaPresetId),
      isFalse,
    );
  });

  test('a user edited Mangaka is not overwritten on launch', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final role = preset.copyWith(
      personaPrompt: 'my persona',
      recipeId: 'my recipe',
      agentMode: RoleAgentMode.chat,
    );
    await database
        .into(database.conversations)
        .insert(ConversationConverter.toCompanion(role));
    final stored = (await container().read(
      conversationsProvider.future,
    )).firstWhere((r) => r.id == kMangakaPresetId);
    expect(stored.personaPrompt, 'my persona');
    expect(stored.recipeId, 'my recipe');
    expect(stored.agentMode, RoleAgentMode.chat);
  });

  test('empty Mangaka body upgrades without changing user bindings', () async {
    final preset = (await PresetCharactersLoader.load()).firstWhere(
      (r) => r.id == kMangakaPresetId,
    );
    final current = preset.copyWith(
      agentMode: RoleAgentMode.chat,
      recipeId: 'my-recipe',
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '',
        extraPrompt: 'my extra',
        customDrawingPrompt: 'my drawing',
        drawingPresetId: 'my-preset',
        drawingPromptPackId: 'my-pack',
        drawingToolPresetName: 'my-tool',
        drawingArtistPresetName: 'my-artist',
      ),
    );
    await database
        .into(database.conversations)
        .insert(ConversationConverter.toCompanion(current));
    final updated = (await container().read(
      conversationsProvider.future,
    )).firstWhere((r) => r.id == kMangakaPresetId);
    final parts = PersonaPromptCodec.parse(updated.personaPrompt);
    expect(
      parts.userPrompt,
      PersonaPromptCodec.parse(preset.personaPrompt).userPrompt,
    );
    expect(updated.recipeId, 'my-recipe');
    expect(updated.agentMode, RoleAgentMode.tool);
    expect(parts.extraPrompt, 'my extra');
    expect(parts.customDrawingPrompt, 'my drawing');
    expect(parts.drawingPresetId, 'my-preset');
    expect(parts.drawingPromptPackId, 'my-pack');
    expect(parts.drawingToolPresetName, 'my-tool');
    expect(parts.drawingArtistPresetName, 'my-artist');
    expect(
      updatedMangakaPersona(
        current.copyWith(personaPrompt: 'user edited'),
        preset,
      ),
      isNull,
    );
    expect(
      await container()
          .read(messageRepositoryProvider)
          .getByConversation(kMangakaPresetId),
      isEmpty,
    );
  });

  test('preset overwrite preserves only the current extra prompt', () async {
    final shipped = (await PresetCharactersLoader.load()).firstWhere(
      (c) => c.id == kAicoveAssistantId,
    );
    final preset = shipped.copyWith(
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '新版系统人设',
        extraPrompt: '预设附加不要保留',
        customDrawingPrompt: '预设绘图',
        drawingPresetId: 'preset-drawing',
      ),
    );
    final current = shipped.copyWith(
      isMuted: true,
      personaPrompt: PersonaPromptCodec.compose(
        userPrompt: '旧系统人设',
        extraPrompt: '用户附加',
        customDrawingPrompt: '旧绘图',
        drawingPresetId: 'old-drawing',
      ),
    );
    final updated = overwrittenAssistant(current, preset);
    final parts = PersonaPromptCodec.parse(updated.personaPrompt);
    expect(parts.userPrompt, '新版系统人设');
    expect(parts.extraPrompt, '用户附加');
    expect(parts.customDrawingPrompt, '预设绘图');
    expect(parts.drawingPresetId, 'preset-drawing');
    expect(updated.isMuted, isTrue);
    final empty = overwrittenAssistant(
      current.copyWith(personaPrompt: '旧人设'),
      preset,
    );
    expect(PersonaPromptCodec.parse(empty.personaPrompt).extraPrompt, '');
  });

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
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '我自己改过的设定',
            extraPrompt: '保留我的补充',
          ),
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
    final storedParts = PersonaPromptCodec.parse(stored.personaPrompt);
    expect(
      storedParts.userPrompt,
      PersonaPromptCodec.parse(preset.personaPrompt).userPrompt,
    );
    expect(storedParts.extraPrompt, '保留我的补充');
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

class _FailMangakaOnce extends ConversationRepository {
  _FailMangakaOnce(super.database);
  bool failed = false;

  @override
  Future<void> upsert(ConversationsCompanion data) async {
    if (data.id.value == kMangakaPresetId && !failed) {
      failed = true;
      throw StateError('injected Mangaka storage failure');
    }
    await super.upsert(data);
  }
}

class _FailGreetingOnce extends MessageRepository {
  _FailGreetingOnce(super.database);
  bool failed = false;

  @override
  Future<void> insert(MessagesCompanion data) async {
    if (data.conversationId.value == kMangakaPresetId && !failed) {
      failed = true;
      throw StateError('injected greeting storage failure');
    }
    await super.insert(data);
  }
}
