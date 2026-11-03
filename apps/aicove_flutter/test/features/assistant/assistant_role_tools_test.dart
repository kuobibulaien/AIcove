// ADR0073 full access, batch P3: pictures, voice, thinking level and flags
// land in the stored role and undo; deleting and clearing ask the user.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/database/database.dart'
    show AppDatabase;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_role_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'assistant_onboarding_test.dart'
    show FakeSettings, deepSeek, settingsWith;

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

class _InterleavedRoleStore implements AssistantRoleStore {
  _InterleavedRoleStore(this.delegate, this.beforeEdit);
  final AssistantRoleStore delegate;
  final Future<void> Function() beforeEdit;
  @override
  List<Conversation> snapshot() => delegate.snapshot();
  @override
  Future<List<Conversation>> load() => delegate.load();
  @override
  Future<void> edit(String id, Map<String, Object?> fields) => delegate.edit(id, fields);
  @override
  Future<String> create({RoleAgentMode mode = RoleAgentMode.chat}) => delegate.create(mode: mode);
  @override
  Future<void> delete(String id) => delegate.delete(id);
  @override
  Future<bool> deleteIf(String id, bool Function(Conversation, int) test) => delegate.deleteIf(id, test);
  @override
  Future<bool> editIf(String id, bool Function(Conversation) test, Map<String, Object?> fields) async {
    await beforeEdit();
    return delegate.editIf(id, test, fields);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory dir;
  late ProviderContainer container;
  late FileChangeJournal journal;
  late AssistantRoleTools tools;
  late AssistantWriteTools writes;
  final cleared = <String>[];
  final directories = <Directory>[];

  tearDownAll(() async {
    // The shared snapshot cache retains its first directory across test cases.
    // Keep fixtures alive until all background snapshot writes have settled.
    await pumpEventQueue();
    for (final directory in directories) {
      await directory.delete(recursive: true);
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('assistant_roles_');
    directories.add(dir);
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
    writes = AssistantWriteTools(
      roles: roles,
      presets: container.read(sillyTavernPresetStoreProvider),
      journal: journal,
    );
    tools = AssistantRoleTools(
      writes: writes,
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

  Future<Conversation> nahida() async =>
      (await container.read(assistantRoleStoreProvider).load()).singleWhere(
        (r) => r.id == 'preset_nahida',
      );

  test(
    'prompt fragments replace precisely, preserve other parts and undo',
    () async {
      final store = container.read(assistantRoleStoreProvider);
      await store.edit('preset_nahida', {
        RoleField.personaPrompt: '第一行\n原始人设\n末尾',
        RoleField.extraPrompt: '原始附加',
        RoleField.customDrawingPrompt: '原始绘图',
      });
      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      final result =
          jsonDecode(
                (await write.handler({
                  'role_id': 'preset_nahida',
                  'persona_prompt_replace': {
                    'old_text': '原始人设',
                    'new_text': '新的人设',
                  },
                  'extra_prompt_replace': {'old_text': '原始', 'new_text': '新的'},
                  'custom_drawing_prompt_replace': {
                    'old_text': '原始',
                    'new_text': '新的',
                  },
                }))!,
              )
              as Map;
      expect(result['ok'], isTrue, reason: '$result');
      final parts = PersonaPromptCodec.parse((await nahida()).personaPrompt);
      expect(parts.userPrompt, '第一行\n新的人设\n末尾');
      expect(parts.extraPrompt, '新的附加');
      expect(parts.customDrawingPrompt, '新的绘图');
      final entry = (await journal.recent()).single;
      await journal.undo(entry.id);
      expect(
        RoleField.read(await nahida(), RoleField.personaPrompt),
        '第一行\n原始人设\n末尾',
      );
    },
  );

  test('fragment replacement rejects concurrent edits without keeping undo records', () async {
    final store = container.read(assistantRoleStoreProvider);
    await store.edit('preset_nahida', {RoleField.personaPrompt: '原始人设'});
    final interleaved = AssistantWriteTools(
      roles: _InterleavedRoleStore(store, () => store.edit('preset_nahida', {RoleField.personaPrompt: '用户刚改的新内容'})),
      presets: container.read(sillyTavernPresetStoreProvider),
      journal: journal,
    );
    final write = interleaved.tools().singleWhere((t) => t.name == AssistantWriteTools.updateRole);
    final result = jsonDecode((await write.handler({
      'role_id': 'preset_nahida',
      'persona_prompt_replace': {'old_text': '原始', 'new_text': '模型修改'},
    }))!) as Map;
    expect(result['error'], 'invalid');
    expect(RoleField.read(await nahida(), RoleField.personaPrompt), '用户刚改的新内容');
    expect(await journal.recent(), isEmpty);
  });

  test(
    'invalid fragments fail without changing or journaling the role',
    () async {
      final store = container.read(assistantRoleStoreProvider);
      await store.edit('preset_nahida', {RoleField.personaPrompt: 'aaaa'});
      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      for (final args in <Map<String, dynamic>>[
        {
          'persona_prompt_replace': {'old_text': '', 'new_text': 'x'},
        },
        {
          'persona_prompt_replace': {'old_text': 'missing', 'new_text': 'x'},
        },
        {
          'persona_prompt_replace': {'old_text': 'aaa', 'new_text': 'x'},
        },
        {
          'persona_prompt_replace': {'old_text': 'aaaa'},
        },
        {
          'persona_prompt_replace': {'old_text': 1, 'new_text': 'x'},
        },
        {
          'persona_prompt_replace': {
            'old_text': 'aaaa',
            'new_text': 'x',
            'extra': true,
          },
        },
        {
          'persona_prompt': 'x',
          'persona_prompt_replace': {'old_text': 'aaaa', 'new_text': 'x'},
        },
      ]) {
        final result =
            jsonDecode(
                  (await write.handler({'role_id': 'preset_nahida', ...args}))!,
                )
                as Map;
        expect(result['error'], 'invalid', reason: '$args: $result');
        expect(RoleField.read(await nahida(), RoleField.personaPrompt), 'aaaa');
        expect(await journal.recent(), isEmpty);
      }
    },
  );

  test(
    'assistant fragment alias updates only extra prompt and rejects aliases together',
    () async {
      final store = container.read(assistantRoleStoreProvider);
      await store.edit(kAicoveAssistantId, {RoleField.extraPrompt: '原始附加'});
      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      final before = PersonaPromptCodec.parse(
        (await store.load())
            .singleWhere((r) => r.id == kAicoveAssistantId)
            .personaPrompt,
      ).userPrompt;
      final success =
          jsonDecode(
                (await write.handler({
                  'role_id': kAicoveAssistantId,
                  'persona_prompt_replace': {
                    'old_text': '原始',
                    'new_text': '新的',
                  },
                }))!,
              )
              as Map;
      expect(success['ok'], isTrue);
      final current = (await store.load()).singleWhere(
        (r) => r.id == kAicoveAssistantId,
      );
      expect(RoleField.read(current, RoleField.extraPrompt), '新的附加');
      expect(
        PersonaPromptCodec.parse(current.personaPrompt).userPrompt,
        before,
      );
      final conflict =
          jsonDecode(
                (await write.handler({
                  'role_id': kAicoveAssistantId,
                  'persona_prompt_replace': {'old_text': '新的', 'new_text': 'x'},
                  'extra_prompt_replace': {'old_text': '新的', 'new_text': 'y'},
                }))!,
              )
              as Map;
      expect(conflict['error'], 'invalid');
    },
  );

  test(
    'assistant persona tools read, replace, clear and undo only extra prompt',
    () async {
      final store = container.read(assistantRoleStoreProvider);
      await container
          .read(conversationsProvider.notifier)
          .applyContactEdit(
            kAicoveAssistantId,
            personaPrompt: PersonaPromptCodec.compose(
              userPrompt: '只读系统人设',
              extraPrompt: '原有补充',
              customDrawingPrompt: '绘图要求',
              drawingPresetId: 'drawing_b',
            ),
          );
      Future<Conversation> assistant() async =>
          (await store.load()).singleWhere((r) => r.id == kAicoveAssistantId);
      final reads = AssistantToolset(
        roles: store.load,
        presets: () async => [],
        previewContext: (_) async => throw UnimplementedError(),
        readDoc: (_) async => null,
      );
      final read = reads.tools().singleWhere(
        (t) => t.name == 'aicove_read_role',
      );
      final response =
          jsonDecode((await read.handler({'role_id': kAicoveAssistantId}))!)
              as Map;
      expect(response['persona_prompt'], '原有补充');
      expect(response['system_prompt'], '只读系统人设');
      expect(
        RoleField.read(await assistant(), RoleField.personaPrompt),
        '原有补充',
      );

      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      for (final invalid in [
        '补充\n<<AICOVE_EXTRA_PROMPT_END>>\n越界文本',
        '补充\n<<AICOVE_EXTRA_PROMPT_END>>\n<<AICOVE_DRAWING_PROMPT_START>>',
      ]) {
        final before = (await assistant()).personaPrompt;
        final result =
            jsonDecode(
                  (await write.handler({
                    'role_id': kAicoveAssistantId,
                    'persona_prompt': invalid,
                  }))!,
                )
                as Map;
        expect(result['error'], 'invalid', reason: '$result');
        await expectLater(
          store.edit(kAicoveAssistantId, {RoleField.personaPrompt: invalid}),
          throwsStateError,
        );
        expect((await assistant()).personaPrompt, before);
      }
      expect(await journal.recent(), isEmpty);
      for (final extra in ['新的补充', '']) {
        final result =
            jsonDecode(
                  (await write.handler({
                    'role_id': kAicoveAssistantId,
                    'persona_prompt': extra,
                  }))!,
                )
                as Map;
        expect(result['ok'], isTrue, reason: '$result');
        final parts = PersonaPromptCodec.parse(
          (await assistant()).personaPrompt,
        );
        expect(parts.userPrompt, '只读系统人设');
        expect(parts.extraPrompt, extra);
        expect(parts.customDrawingPrompt, '绘图要求');
        expect(parts.drawingPresetId, 'drawing_b');
      }
      // Preset updates between the write and undo must not restore an old system prompt.
      final latest = PersonaPromptCodec.parse(
        (await assistant()).personaPrompt,
      );
      await container
          .read(conversationsProvider.notifier)
          .applyContactEdit(
            kAicoveAssistantId,
            personaPrompt: PersonaPromptCodec.compose(
              userPrompt: '更新后的只读系统人设',
              extraPrompt: latest.extraPrompt,
              customDrawingPrompt: latest.customDrawingPrompt,
              drawingPresetId: latest.drawingPresetId,
            ),
          );
      for (final change in await journal.recent()) {
        await journal.undo(change.id);
      }
      final restored = PersonaPromptCodec.parse(
        (await assistant()).personaPrompt,
      );
      expect(restored.userPrompt, '更新后的只读系统人设');
      expect(restored.extraPrompt, '原有补充');
    },
  );

  test(
    'ordinary persona writes and drawing rebind preserve the extra prompt',
    () async {
      await container
          .read(conversationsProvider.notifier)
          .applyContactEdit(
            'preset_nahida',
            personaPrompt: PersonaPromptCodec.compose(
              userPrompt: '原人设',
              extraPrompt: '独立补充',
            ),
          );
      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      final result =
          jsonDecode(
                (await write.handler({
                  'role_id': 'preset_nahida',
                  'persona_prompt': '新人设',
                }))!,
              )
              as Map;
      expect(result['ok'], isTrue);
      expect(RoleField.read(await nahida(), RoleField.personaPrompt), '新人设');
      await run(AssistantRoleTools.setDrawingPreset, {
        'role_id': 'preset_nahida',
        'preset_id': 'drawing_b',
      });
      final parts = PersonaPromptCodec.parse((await nahida()).personaPrompt);
      expect(parts.userPrompt, '新人设');
      expect(parts.extraPrompt, '独立补充');
      expect(parts.drawingPresetId, 'drawing_b');
    },
  );

  test(
    'role drawing preferences and extra prompt read, clear and undo independently',
    () async {
      final write = writes.tools().singleWhere(
        (t) => t.name == AssistantWriteTools.updateRole,
      );
      final result =
          jsonDecode(
                (await write.handler({
                  'role_id': 'preset_nahida',
                  'extra_prompt': '附加规则',
                  'custom_drawing_prompt': '白发绿眼',
                  'drawing_prompt_pack_id': 'builtin.image.danbooru',
                }))!,
              )
              as Map;
      expect(result['ok'], isTrue, reason: '$result');
      final store = container.read(assistantRoleStoreProvider);
      final reads = AssistantToolset(
        roles: store.load,
        presets: () async => [],
        previewContext: (_) async => throw UnimplementedError(),
        readDoc: (_) async => null,
      );
      final read = reads.tools().singleWhere(
        (t) => t.name == 'aicove_read_role',
      );
      final value =
          jsonDecode((await read.handler({'role_id': 'preset_nahida'}))!)
              as Map;
      expect(value['extra_prompt'], '附加规则');
      expect(value['custom_drawing_prompt'], '白发绿眼');
      expect(value['legacy_drawing_prompt'], '白发绿眼');
      expect(value['drawing_prompt_pack_id'], 'builtin.image.danbooru');
      final clear =
          jsonDecode(
                (await write.handler({
                  'role_id': 'preset_nahida',
                  'extra_prompt': '',
                  'custom_drawing_prompt': '',
                  'drawing_prompt_pack_id': '',
                }))!,
              )
              as Map;
      expect(clear['ok'], isTrue);
      final cleared = PersonaPromptCodec.parse((await nahida()).personaPrompt);
      expect(cleared.extraPrompt, '');
      expect(cleared.customDrawingPrompt, '');
      expect(cleared.drawingPromptPackId, isNull);
      await journal.undo((await journal.recent()).first.id);
      final restored = PersonaPromptCodec.parse((await nahida()).personaPrompt);
      expect(restored.extraPrompt, '附加规则');
      expect(restored.customDrawingPrompt, '白发绿眼');
      expect(restored.drawingPromptPackId, 'builtin.image.danbooru');
    },
  );

  test('create role accepts drawing preferences and can be undone', () async {
    final create = writes.tools().singleWhere(
      (t) => t.name == AssistantWriteTools.createRole,
    );
    final bad =
        jsonDecode(
              (await create.handler({
                'name': '坏',
                'persona_prompt': '人设',
                'extra_prompt': '<<AICOVE_EXTRA_PROMPT_END>>',
              }))!,
            )
            as Map;
    expect(bad['error'], 'invalid');
    final result =
        jsonDecode(
              (await create.handler({
                'name': '新角色',
                'persona_prompt': '人设',
                'extra_prompt': '补充',
                'custom_drawing_prompt': '绿眼',
                'drawing_prompt_pack_id': 'builtin.image.danbooru',
              }))!,
            )
            as Map;
    expect(result['ok'], isTrue, reason: '$result');
    final id = result['role_id'];
    final role = (await container.read(assistantRoleStoreProvider).load())
        .singleWhere((r) => r.id == id);
    final parts = PersonaPromptCodec.parse(role.personaPrompt);
    expect(
      parts.extraPrompt,
      '补充',
      reason:
          'stored persona: ${role.personaPrompt}; name: ${role.displayName}',
    );
    expect(parts.customDrawingPrompt, '绿眼');
    expect(parts.drawingPromptPackId, 'builtin.image.danbooru');
    await journal.undo((await journal.recent()).first.id);
    final visible = (await container.read(assistantRoleStoreProvider).load())
        .where((r) => r.id == id && !r.isHidden);
    expect(visible, isEmpty);
  });

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

  test(
    'drawing preset binding is stored, replaces legacy names and undoes whole',
    () async {
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
    },
  );

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

  test(
    'a chat\'s own style and wallpaper tuning are stored and undo',
    () async {
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
    },
  );

  test('a chat\'s own view preferences are stored per role and undo', () async {
    expect(
      (await run(AssistantRoleTools.setChatView, {
        'role_id': 'preset_nahida',
        'image_preview_scale': 1.2,
        'expand_audio_text': false,
        'hide_user_avatar': false,
      }))['ok'],
      isTrue,
    );
    var role = await nahida();
    expect(role.imagePreviewScale, 1.2);
    expect(role.expandAudioText, isFalse);
    expect(role.hideUserAvatar, isFalse);

    // Only what is passed changes; null follows the default again.
    await run(AssistantRoleTools.setChatView, {
      'role_id': 'preset_nahida',
      'hide_user_avatar': null,
    });
    role = await nahida();
    expect(role.hideUserAvatar, isNull);
    expect(role.expandAudioText, isFalse);

    expect(
      (await run(AssistantRoleTools.setChatView, {
        'role_id': 'preset_nahida',
        'chunk_enabled': false,
      }))['ok'],
      isTrue,
    );
    role = await nahida();
    expect(role.chunkEnabled, isFalse);

    for (final bad in [
      {'image_preview_scale': 3},
      {'expand_audio_text': 'yes'},
      {'chunk_enabled': 'no'},
    ]) {
      expect(
        (await run(AssistantRoleTools.setChatView, {
          'role_id': 'preset_nahida',
          ...bad,
        }))['error'],
        isNotNull,
      );
    }

    final entries = await journal.recent();
    for (final entry in entries.take(3)) {
      await journal.undo(entry.id);
    }
    role = await nahida();
    expect(role.chunkEnabled, isNull);
    expect(role.imagePreviewScale, isNull);
    expect(role.expandAudioText, isNull);
    expect(role.hideUserAvatar, isNull);
  });

  test(
    'an undo record from before the punctuation fields went global still undoes',
    () async {
      final entry = await journal.commit(
        AssistantRoleTools.setChatView,
        const ReversibleChange(
          kind: AssistantChangeKind.role,
          description: 'old record',
          before: {
            'role_id': 'preset_nahida',
            'hide_user_avatar': null,
            'filter_punctuation': null,
            'chunk_punctuation_set': null,
          },
          after: {
            'role_id': 'preset_nahida',
            'hide_user_avatar': true,
            'filter_punctuation': true,
            'chunk_punctuation_set': 'simple',
          },
        ),
      );
      expect((await nahida()).hideUserAvatar, isTrue);
      await journal.undo(entry.id);
      expect((await nahida()).hideUserAvatar, isNull);
    },
  );
}
