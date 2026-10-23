// ADR0073 full access, batch P3: pictures, voice, thinking level and flags
// land in the stored role and undo; deleting and clearing ask the user.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' show AppDatabase;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_role_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'assistant_onboarding_test.dart' show FakeSettings, deepSeek, settingsWith;

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dir;
  late ProviderContainer container;
  late FileChangeJournal journal;
  late AssistantRoleTools tools;
  final cleared = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('assistant_roles_');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    addTearDown(() => PathProviderPlatform.instance = previousPaths);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(
          () => FakeSettings(
            settingsWith([
              deepSeek(keys: const ['sk-1']),
            ], 'deepseek:deepseek-flash'),
          ),
        ),
      ],
    );
    await container.read(conversationsProvider.future);
    final roles = container.read(assistantRoleStoreProvider);
    journal = FileChangeJournal(
      file: () async => File('${dir.path}/journal.json'),
      appliers: assistantChangeAppliers(
        roles: roles,
        presets: container.read(sillyTavernPresetStoreProvider),
      ),
    );
    tools = AssistantRoleTools(
      writes: AssistantWriteTools(
        roles: roles,
        presets: container.read(sillyTavernPresetStoreProvider),
        journal: journal,
      ),
      roles: roles.load,
      rolesNow: roles.snapshot,
      settings: () => container.read(appSettingsProvider.future),
      voices: () => [
        VoicePreset.defaultPreset,
        VoicePreset.defaultPreset.copyWith(id: 'voice_b', name: '小雪的声音'),
      ],
      cards: () => container.read(assistantCardsProvider.notifier),
      deleteRole: roles.delete,
      clearChat: (id) async => cleared.add(id),
      drawingPresets: () async => [
        (id: 'drawing_default', name: '默认绘图'),
        (id: 'drawing_b', name: '水彩'),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
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

  Future<Conversation> nahida() async =>
      (await container.read(assistantRoleStoreProvider).load()).singleWhere(
        (r) => r.id == 'preset_nahida',
      );

  test('pictures, voice, thinking and pinning are stored and undo', () async {
    final before = await nahida();
    expect(
      (await run(AssistantRoleTools.setLook, {
        'role_id': 'preset_nahida',
        'avatar': 'builtin:aicove',
        'wallpaper': 'role:preset_nahida:portrait',
      }))['ok'],
      isTrue,
    );
    await run(AssistantRoleTools.setVoice, {
      'role_id': 'preset_nahida',
      'voice_id': 'voice_b',
    });
    await run(AssistantRoleTools.setThinking, {
      'role_id': 'preset_nahida',
      'level': 'high',
    });
    await run(AssistantRoleTools.setFlags, {
      'role_id': 'preset_nahida',
      'pinned': !before.isPinned,
    });

    final after = await nahida();
    expect(after.avatarUrl, kAssistantBuiltinImages['aicove']);
    expect(after.chatBackgroundImage, before.characterImage);
    expect(after.chatBackgroundFraming, isNull);
    expect(after.voiceFile, 'voice_b');
    expect(after.thinkingLevels['deepseek:deepseek-flash']?.name, 'high');
    expect(after.isPinned, !before.isPinned);

    for (final entry in await journal.recent()) {
      await journal.undo(entry.id);
    }
    final undone = await nahida();
    expect(undone.avatarUrl, before.avatarUrl);
    expect(undone.chatBackgroundImage, before.chatBackgroundImage);
    expect(undone.voiceFile, before.voiceFile);
    expect(undone.thinkingLevels, isEmpty);
    expect(undone.isPinned, before.isPinned);
  });

  test('drawing preset binding is stored, replaces legacy names and undoes whole', () async {
    // A legacy by-name binding, as old roles carry.
    await container
        .read(conversationsProvider.notifier)
        .applyContactEdit(
          'preset_nahida',
          personaPrompt: PersonaPromptCodec.compose(
            userPrompt: '我是纳西妲',
            drawingToolPresetName: '旧工具',
          ),
        );
    final result = await run(AssistantRoleTools.setDrawingPreset, {
      'role_id': 'preset_nahida',
      'preset_id': 'drawing_b',
    });
    expect(result['ok'], isTrue, reason: '$result');
    var parts = PersonaPromptCodec.parse((await nahida()).personaPrompt);
    expect(parts.drawingPresetId, 'drawing_b');
    expect(parts.drawingToolPresetName, isNull);
    expect(parts.userPrompt, '我是纳西妲');

    expect(
      (await run(AssistantRoleTools.setDrawingPreset, {
        'role_id': 'preset_nahida',
        'preset_id': 'nope',
      }))['error'],
      'invalid',
    );

    await journal.undo((await journal.recent()).first.id);
    parts = PersonaPromptCodec.parse((await nahida()).personaPrompt);
    expect(parts.drawingPresetId, isNull);
    expect(parts.drawingToolPresetName, '旧工具');
    expect(parts.userPrompt, '我是纳西妲');
  });

  test('unknown voices and image sources are refused', () async {
    expect(
      (await run(AssistantRoleTools.setVoice, {
        'role_id': 'preset_nahida',
        'voice_id': 'nope',
      }))['error'],
      'invalid',
    );
    expect(
      (await run(AssistantRoleTools.setLook, {
        'role_id': 'preset_nahida',
        'avatar': 'https://example.com/a.png',
      }))['error'],
      'invalid',
    );
  });

  test('deleting and clearing always ask the user', () async {
    expect(
      tools.riskOf(AssistantRoleTools.deleteRoleTool, {}),
      AssistantRisk.major,
    );
    expect(
      tools.riskOf(AssistantRoleTools.clearChatTool, {}),
      AssistantRisk.major,
    );
    await run(AssistantRoleTools.clearChatTool, {'role_id': 'preset_nahida'});
    expect(cleared, ['preset_nahida']);
    await run(AssistantRoleTools.deleteRoleTool, {'role_id': 'preset_nahida'});
    expect(
      (await container.read(assistantRoleStoreProvider).load()).map(
        (r) => r.id,
      ),
      isNot(contains('preset_nahida')),
    );
  });

  test('picking an image and importing a card only put up cards', () async {
    await run(AssistantRoleTools.pickImage, {
      'role_id': 'preset_nahida',
      'slot': 'avatar',
    });
    await run(AssistantRoleTools.importCard, {});
    final cards = container.read(assistantCardsProvider);
    expect(cards.whereType<AssistantImagePick>().single.slot, 'avatar');
    expect(cards.whereType<AssistantRoleImport>().single.url, isNull);
  });

  test('a chat\'s own style and wallpaper tuning are stored and undo', () async {
    // No wallpaper of its own: tuning it would not show.
    expect(
      (await run(AssistantRoleTools.setChatView, {
        'role_id': 'preset_nahida',
        'wallpaper_mask': 0.5,
      }))['error'],
      isNotNull,
    );
    await run(AssistantRoleTools.setLook, {
      'role_id': 'preset_nahida',
      'wallpaper': 'builtin:aicove',
    });

    expect(
      (await run(AssistantRoleTools.setChatView, {
        'role_id': 'preset_nahida',
        'display_style': 'document',
        'wallpaper_mask': 0.5,
        'wallpaper_blur': 6,
      }))['ok'],
      isTrue,
    );
    var role = await nahida();
    expect(role.chatDisplayStyle, ChatDisplayStyle.document);
    expect(role.chatBackgroundMaskOpacity, 0.5);
    expect(role.chatBackgroundBlurSigma, 6);

    // Only what is passed changes; null puts the default back.
    await run(AssistantRoleTools.setChatView, {
      'role_id': 'preset_nahida',
      'wallpaper_blur': null,
    });
    role = await nahida();
    expect(role.chatBackgroundMaskOpacity, 0.5);
    expect(role.chatBackgroundBlurSigma, isNull);

    expect(
      (await run(AssistantRoleTools.setChatView, {
        'role_id': 'preset_nahida',
        'wallpaper_mask': 2,
      }))['error'],
      isNotNull,
    );

    final entries = await journal.recent();
    await journal.undo(entries[0].id);
    await journal.undo(entries[1].id);
    role = await nahida();
    expect(role.chatDisplayStyle, isNull);
    expect(role.chatBackgroundMaskOpacity, isNull);
    expect(role.chatBackgroundBlurSigma, isNull);
  });
}
