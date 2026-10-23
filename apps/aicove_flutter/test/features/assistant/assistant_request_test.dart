// ADR0073 T2/T3: the assistant's tools reach only its own requests, read
// real roles, presets and assembled context, and write through the review
// gate and the change journal.
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateDecision, GateOutcome, KernelToolCall, ToolCallScope, ToolEffect;
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_approvals.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_write_tools.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/assistant/domain/aicove_docs.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/persona_prompt_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _CountingKeeper extends MemoryKeeperService {
  _CountingKeeper({required super.store})
    : super(
        loadMessages: (_) async => const [],
        compactedBoundaries: (_) async => const {},
        agentFactory: () => throw StateError('memory agent disabled'),
        allowed: (_) async => false,
      );

  final resumed = <String>[];

  @override
  void resumeOnce(String ownerId) => resumed.add(ownerId);
}

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

final _now = DateTime.utc(2026, 10, 17, 10);
const _model = 'openai:gpt-4o';

AppSettings _settings() =>
    mapUiModelsToAppSettings({'context_window_tokens': 272000}).copyWith(
      defaultModelName: _model,
      defaultChatModels: const [_model],
      modelConfigs: {
        _model: ModelConfig(chatCapabilities: const ['tools']),
      },
      modelTypes: const {_model: 'chat'},
      providers: const [
        ProviderAuth(
          id: 'openai',
          apiKeys: ['test-key'],
          apiBaseUrl: 'https://api.openai.com/v1',
        ),
      ],
      modelProviderMap: const {_model: 'openai', 'gpt-4o': 'openai'},
    );

const _personaText = '你是测试角色小理，说话很短。';

Conversation _role(String id, {bool hidden = false}) => Conversation(
  id: id,
  title: id,
  displayName: id == 'role_li' ? '小理' : id,
  personaPrompt: PersonaPromptCodec.compose(userPrompt: _personaText),
  isHidden: hidden,
  createdAt: _now,
  updatedAt: _now,
  messages: const [],
);

final _history = [
  Message(id: 'u1', role: 'user', content: '我的秘密日记内容', createdAt: _now),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _CountingKeeper keeper;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('assistant_request_');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    final database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(() => _Settings(_settings())),
        requestClockProvider.overrideWithValue(() => _now),
        memoryKeeperProvider.overrideWith(
          (ref) =>
              keeper = _CountingKeeper(store: ref.read(memoryStoreProvider)),
        ),
        sillyTavernPresetStoreProvider.overrideWithValue(
          SillyTavernPresetStore(documentsDirectoryResolver: () async => root),
        ),
      ],
    );
    addTearDown(() async {
      // Role edits write their edit snapshot in the background; let it land
      // before the directory goes.
      await pumpEventQueue();
      container.dispose();
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // A late background write raced the cleanup; the temp dir is moot.
      }
    });
    await container.read(appSettingsProvider.future);
    final repo = container.read(conversationRepositoryProvider);
    for (final role in [_role('role_li'), _role('role_secret', hidden: true)]) {
      await repo.upsert(ConversationConverter.toCompanion(role));
    }
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: 'li_u1',
            conversationId: 'role_li',
            role: 'user',
            content: '小理的私密聊天内容',
            status: const Value('sent'),
            createdAt: _now.millisecondsSinceEpoch,
          ),
        );
    await container.read(conversationsProvider.future);
  });

  Future<ApiConfig> prepare(Conversation conv) => container
      .read(chatSendServiceProvider)
      .prepareApiConfig(conv: conv, history: _history, userText: '帮我看看');

  List<String> toolsOf(ApiConfig config) => [
    for (final tool in config.tools ?? const [])
      (tool['function'] as Map)['name'] as String,
  ];

  Future<Map<String, dynamic>> call(
    ApiConfig config,
    String name, [
    Map<String, dynamic> args = const {},
  ]) async {
    final tool = config.boundTools!.singleWhere((t) => t.name == name);
    return jsonDecode((await tool.handler(args))!) as Map<String, dynamic>;
  }

  Conversation assistant() => container
      .read(conversationsProvider)
      .value!
      .singleWhere((c) => c.id == kAicoveAssistantId);

  test('only the assistant conversation gets the assistant tools', () async {
    final own = await prepare(assistant());
    final other = await prepare(_role('role_li'));

    expect(
      own.boundTools!
          .where((t) => t.exposure == ToolExposure.codemode)
          .map((t) => t.name),
      containsAll([
        'aicove_docs_read',
        'aicove_list_roles',
        'aicove_read_role',
        'aicove_inspect_context',
      ]),
    );
    expect(toolsOf(own), contains('codemode'));
    expect(toolsOf(own).where((t) => t.startsWith('aicove_')), isEmpty);
    expect(jsonEncode(own.tools), contains('aicove_inspect_context'));
    expect(
      other.boundTools?.where((t) => t.name.startsWith('aicove_')) ?? [],
      isEmpty,
    );
    expect(toolsOf(other).where((t) => t.startsWith('aicove_')), isEmpty);
    expect(jsonEncode(other.messages), isNot(contains('住在 AIcove 里的小管家')));
  });

  test('roles in the privacy space stay invisible', () async {
    final config = await prepare(assistant());
    final listed = await call(config, 'aicove_list_roles');
    final ids = [for (final r in listed['roles'] as List) (r as Map)['id']];
    expect(ids, contains('role_li'));
    expect(ids, isNot(contains('role_secret')));

    final card = await call(config, 'aicove_read_role', {'role_id': 'role_li'});
    expect(card['persona_prompt'], _personaText);
    // Roles that never narrowed their plugins drop to the defaults on load.
    expect(card['plugins'], ['memory', 'time_awareness']);
    final hidden = await call(config, 'aicove_read_role', {
      'role_id': 'role_secret',
    });
    expect(hidden['error'], 'not_found');
  });

  test('context inspection runs the real assembly without chat text', () async {
    final config = await prepare(assistant());
    final report = await call(config, 'aicove_inspect_context', {
      'role_id': 'role_li',
    });

    expect(report['role'], '小理');
    expect(report['input_tokens'], greaterThan(0));
    expect(report['plugins'], isA<List>());
    expect(report['system_sources'], isNotEmpty);
    // Assembled sources mix in chat text and memories: sizes only.
    final text = jsonEncode(report);
    expect(text, isNot(contains('你是测试角色小理')));
    expect(text, isNot(contains('私密聊天内容')));
    expect(text, isNot(contains('秘密日记')));
    expect((report['messages'] as Map)['user'], isNotNull);
  });

  test('preset warnings never carry expanded chat text', () async {
    final preset = await container
        .read(sillyTavernPresetStoreProvider)
        .importSource(r'''
{
  "prompts": [
    {"identifier":"main","role":"system","content":"{{unsupported::{{lastUserMessage}}}}"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''', sourceFileName: 'leak.json');
    final repo = container.read(conversationRepositoryProvider);
    await repo.upsert(
      ConversationConverter.toCompanion(
        _role('role_li').copyWith(recipeId: preset.id),
      ),
    );

    final config = await prepare(assistant());
    final report = await call(config, 'aicove_inspect_context', {
      'role_id': 'role_li',
    });

    expect(report['preset'], isNotNull);
    expect(report['warning_count'], greaterThan(0));
    expect(jsonEncode(report), isNot(contains('私密聊天内容')));
  });

  test('previewing a role starts no memory work; a real send does', () async {
    final config = await prepare(assistant());
    keeper.resumed.clear();
    await call(config, 'aicove_inspect_context', {'role_id': 'role_li'});
    expect(keeper.resumed, isEmpty);

    await prepare(_role('role_li'));
    expect(keeper.resumed, contains('role_li'));
  });

  test('every library page ships with the app', () async {
    final config = await prepare(assistant());
    for (final doc in kAicoveDocs) {
      final page = await call(config, 'aicove_docs_read', {'doc': doc.id});
      expect(page['content'], isNotEmpty, reason: doc.id);
    }
    final missing = await call(config, 'aicove_docs_read', {'doc': 'nope'});
    expect(missing['error'], 'not_found');
  });

  group('writes', () {
    Future<Conversation?> roleNow(String id) async {
      final row = await container
          .read(conversationRepositoryProvider)
          .getById(id);
      return row == null || row.deletedAt != null
          ? null
          : ConversationConverter.fromDb(row);
    }

    Future<String> latestChange() async =>
        (await container.read(assistantRecentChangesProvider.future)).first.id;

    Future<void> undo(String id) =>
        container.read(assistantChangeJournalProvider).undo(id);

    test('the assistant run defaults to no approval; previews and other '
        'roles carry none', () async {
      final own = await prepare(assistant());
      final other = await prepare(_role('role_li'));
      GateDecision decide(String tool) => own.toolPolicy!.gate
          .check(
            KernelToolCall(
              id: 'c',
              name: tool,
              arguments: const {'role_id': 'role_li'},
            ),
            ToolEffect.write,
          )
          .decision;

      expect(
        own.boundTools!
            .singleWhere((t) => t.name == AssistantWriteTools.updateRole)
            .exposure,
        ToolExposure.codemode,
      );
      expect(toolsOf(own), isNot(contains(AssistantWriteTools.updateRole)));
      expect(own.toolPolicy!.gate, isA<AssistantToolGate>());
      expect(decide('aicove_read_role'), GateDecision.allow);
      expect(decide(AssistantWriteTools.togglePresetItem), GateDecision.allow);
      expect(decide(AssistantWriteTools.updateRole), GateDecision.allow);
      expect(
        other.boundTools?.where((t) => t.name.startsWith('aicove_')) ?? [],
        isEmpty,
      );
      expect(other.toolPolicy, isNull);
      expect(toolsOf(other), isNot(contains(AssistantWriteTools.updateRole)));
    });

    test(
      'existing per-call switch takes effect inside a prepared run',
      () async {
        final config = await prepare(assistant());
        final gate = config.toolPolicy!.gate;
        const call = KernelToolCall(id: 'shell', name: 'bash');
        expect(
          gate.check(call, ToolEffect.external).decision,
          GateDecision.allow,
        );
        await container.read(assistantAlwaysAskProvider.notifier).set(true);
        expect(
          gate.check(call, ToolEffect.external).decision,
          GateDecision.ask,
        );
        await container.read(assistantAlwaysAskProvider.notifier).set(false);
        expect(
          gate.check(call, ToolEffect.external).decision,
          GateDecision.allow,
        );
      },
    );

    test(
      'default policy reads visible chat and enables external plugins directly',
      () async {
        final config = await prepare(assistant());
        Future<Map<String, dynamic>> allowed(
          String name,
          Map<String, dynamic> args,
        ) => ToolCallScope().run(() async {
          final verdict = config.toolPolicy!.gate.check(
            KernelToolCall(id: name, name: name, arguments: args),
            ToolEffect.write,
          );
          expect(verdict.decision, GateDecision.allow);
          ToolCallScope.current!.outcome = GateOutcome.allowed;
          return call(config, name, args);
        });
        final chat = await allowed('aicove_read_role_chat', {
          'role_id': 'role_li',
        });
        expect(jsonEncode(chat), contains('小理的私密聊天内容'));
        final hidden = await allowed('aicove_read_role_chat', {
          'role_id': 'role_secret',
        });
        expect(hidden['error'], isNotNull);
        final changed = await allowed(AssistantWriteTools.setRolePlugins, {
          'role_id': 'role_li',
          'plugins': ['web_search'],
        });
        expect(changed['ok'], isTrue);
        expect((await roleNow('role_li'))!.enabledPlugins, ['web_search']);
      },
    );

    test(
      'a role edit keeps the drawing preset binding and is undoable, but never '
      'over a later edit',
      () async {
        final repo = container.read(conversationRepositoryProvider);
        await container
            .read(conversationsProvider.notifier)
            .applyContactEdit(
              'role_li',
              personaPrompt: PersonaPromptCodec.compose(
                userPrompt: _personaText,
                drawingPresetId: 'drawing_li',
              ),
            );
        final config = await prepare(assistant());

        final done = await call(config, AssistantWriteTools.updateRole, {
          'role_id': 'role_li',
          'persona_prompt': '你是小理，说话活泼。',
        });
        expect(done['ok'], isTrue);
        var parts = PersonaPromptCodec.parse(
          (await roleNow('role_li'))!.personaPrompt,
        );
        expect(parts.userPrompt, '你是小理，说话活泼。');
        expect(parts.drawingPresetId, 'drawing_li');
        expect(
          (await repo.getById('role_li'))!.personaPrompt,
          contains('说话活泼'),
        );

        await undo(await latestChange());
        parts = PersonaPromptCodec.parse(
          (await roleNow('role_li'))!.personaPrompt,
        );
        expect(parts.userPrompt, _personaText);
        expect(parts.drawingPresetId, 'drawing_li');

        await call(config, AssistantWriteTools.updateRole, {
          'role_id': 'role_li',
          'persona_prompt': '第二版',
        });
        final change = await latestChange();
        await container
            .read(conversationsProvider.notifier)
            .applyContactEdit(
              'role_li',
              personaPrompt: PersonaPromptCodec.compose(userPrompt: '用户手改'),
            );
        await expectLater(undo(change), throwsStateError);
        expect(
          PersonaPromptCodec.parse(
            (await roleNow('role_li'))!.personaPrompt,
          ).userPrompt,
          '用户手改',
        );
      },
    );

    test('undo stops at the privacy space, a used new role, and bad '
        'arguments', () async {
      final config = await prepare(assistant());
      final repo = container.read(conversationRepositoryProvider);
      final writes = container.read(assistantWriteToolsProvider);

      // Descriptions are not stored yet; the tool must refuse them.
      final description = await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_li',
        'description': '新简介',
      });
      expect(description['error'], 'invalid');

      await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_li',
        'self_address': '小理理',
      });
      final edit = await latestChange();
      final li = (await roleNow('role_li'))!;
      await repo.upsert(
        ConversationConverter.toCompanion(li.copyWith(isHidden: true)),
      );
      await expectLater(undo(edit), throwsStateError);
      expect((await roleNow('role_li'))!.selfAddress, '小理理');

      final created = await call(config, AssistantWriteTools.createRole, {
        'name': '小新',
        'persona_prompt': '你是小新。',
      });
      final id = created['role_id'] as String;
      // Not in the list state yet: turning on web search must ask the user.
      expect(
        writes.riskOf(AssistantWriteTools.setRolePlugins, {
          'role_id': 'not_listed_yet',
          'plugins': ['web_search'],
        }),
        AssistantRisk.major,
      );
      final creation = await latestChange();
      final database = container.read(databaseProvider);
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'xin_u1',
              conversationId: id,
              role: 'user',
              content: '你好',
              status: const Value('sent'),
              createdAt: _now.millisecondsSinceEpoch,
            ),
          );
      await expectLater(undo(creation), throwsStateError);
      expect(await roleNow(id), isNotNull);

      final notAList = await call(config, AssistantWriteTools.setRolePlugins, {
        'role_id': id,
        'plugins': 'memory',
      });
      final notABool = await call(
        config,
        AssistantWriteTools.togglePresetItem,
        {
          'preset_id': 'x',
          'kind': 'prompt',
          'item_id': 'main',
          'enabled': 'false',
        },
      );
      expect(notAList['error'], 'invalid');
      expect(notABool['error'], 'invalid');
    });

    test('roles in the privacy space cannot be changed', () async {
      final config = await prepare(assistant());
      final result = await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_secret',
        'persona_prompt': '改掉',
      });
      expect(result['error'], 'invalid');
    });

    test(
      'turning on web search is major; other plugins are reversible',
      () async {
        final config = await prepare(assistant());
        final writes = container.read(assistantWriteToolsProvider);
        await call(config, AssistantWriteTools.setRolePlugins, {
          'role_id': 'role_li',
          'plugins': ['memory'],
        });
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory']);

        // Risk reads the list state, which follows the database watch.
        await pumpEventQueue();
        AssistantRisk? risk(Map<String, dynamic> args) => writes.riskOf(
          AssistantWriteTools.setRolePlugins,
          {'role_id': 'role_li', ...args},
        );
        expect(
          risk({
            'plugins': ['memory', 'image'],
          }),
          AssistantRisk.reversible,
        );
        expect(
          risk({
            'plugins': ['web_search'],
          }),
          AssistantRisk.major,
        );
        expect(risk({'all': true}), AssistantRisk.major);

        final bad = await call(config, AssistantWriteTools.setRolePlugins, {
          'role_id': 'role_li',
          'plugins': ['mcp:evil'],
        });
        expect(bad['error'], 'invalid');
      },
    );

    test(
      'a plugin call only writes over the selection it was rated on',
      () async {
        final config = await prepare(assistant());
        final repo = container.read(conversationRepositoryProvider);
        final writes = container.read(assistantWriteToolsProvider);
        Future<void> setPlugins(List<String> plugins) async {
          final li = (await roleNow('role_li'))!;
          await repo.upsert(
            ConversationConverter.toCompanion(
              li.copyWith(enabledPlugins: plugins, updatedAt: DateTime.now()),
            ),
          );
          await pumpEventQueue();
        }

        // One scope per call, as the gated executor gives each execution.
        ToolCallScope rated(Map<String, dynamic> args, AssistantRisk expected) {
          final scope = ToolCallScope();
          expect(
            scope.run(
              () => writes.riskOf(AssistantWriteTools.setRolePlugins, args),
            ),
            expected,
          );
          return scope;
        }

        Future<Map<String, dynamic>> run(
          ToolCallScope scope,
          Map<String, dynamic> args, {
          GateOutcome outcome = GateOutcome.allowed,
        }) {
          scope.outcome = outcome;
          return scope.run(
            () => call(config, AssistantWriteTools.setRolePlugins, args),
          );
        }

        // Rated with web search already on, then the user turns it off. A
        // second call with the same arguments is rated major; its rating
        // belongs to it, not to call a.
        await setPlugins(['memory', 'web_search']);
        const all = {'role_id': 'role_li', 'all': true};
        final a = rated(all, AssistantRisk.reversible);
        await setPlugins(['memory']);
        final b = rated(all, AssistantRisk.major);
        expect((await run(a, all))['error'], 'invalid');
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory']);
        // A major rating the user did not approve covers nothing.
        expect((await run(b, all))['error'], 'invalid');
        expect(
          (await run(
            rated(all, AssistantRisk.major),
            all,
            outcome: GateOutcome.approved,
          ))['ok'],
          isTrue,
        );
        expect((await roleNow('role_li'))!.enabledPlugins, isNull);
        await undo(await latestChange());
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory']);
        await pumpEventQueue();

        // Rated on one ordinary selection, written over another.
        const image = {
          'role_id': 'role_li',
          'plugins': ['memory', 'image'],
        };
        final c = rated(image, AssistantRisk.reversible);
        await setPlugins(['memory', 'tts']);
        final before =
            (await container.read(assistantChangeJournalProvider).recent())
                .length;
        expect((await run(c, image))['error'], 'invalid');
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory', 'tts']);
        expect(
          (await container.read(assistantChangeJournalProvider).recent())
              .length,
          before,
          reason: 'a refused write leaves no record',
        );

        // Rated again on fresh state, the retry goes through and is undoable.
        expect(
          (await run(rated(image, AssistantRisk.reversible), image))['ok'],
          isTrue,
        );
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory', 'image']);
        await undo(await latestChange());
        expect((await roleNow('role_li'))!.enabledPlugins, ['memory', 'tts']);
      },
    );

    test(
      'a plugin change does not land when its record cannot be kept',
      () async {
        final config = await prepare(assistant());
        final before = (await roleNow('role_li'))!.enabledPlugins;
        final journal = await container
            .read(assistantChangeJournalProvider)
            .file();
        await journal.parent.create(recursive: true);
        await journal.writeAsString('not json');
        final scope = ToolCallScope()..outcome = GateOutcome.allowed;
        Object? failure;
        try {
          final result = await scope.run(
            () => call(config, AssistantWriteTools.setRolePlugins, {
              'role_id': 'role_li',
              'plugins': ['memory', 'image'],
            }),
          );
          failure = result['ok'] == true ? null : result;
        } catch (error) {
          failure = error;
        }
        expect(failure, isNotNull);
        expect((await roleNow('role_li'))!.enabledPlugins, before);
      },
    );

    test('saving one role never writes stale copies of the others', () async {
      await prepare(assistant());
      final repo = container.read(conversationRepositoryProvider);
      // A newer save of role_li the list state has not seen yet.
      final li = (await roleNow('role_li'))!;
      await repo.upsert(
        ConversationConverter.toCompanion(li.copyWith(selfAddress: '新自称')),
      );
      await container
          .read(conversationsProvider.notifier)
          .applyContactEdit(kAicoveAssistantId, addressUser: '学长');
      expect((await roleNow('role_li'))!.selfAddress, '新自称');
    });

    test(
      'a new role checks its fields first and keeps any later edit',
      () async {
        final config = await prepare(assistant());
        final before =
            (await container.read(assistantRoleStoreProvider).load()).length;
        for (final args in [
          {'name': 123, 'persona_prompt': '你是小新。'},
          {
            'name': '小新',
            'persona_prompt': {'text': 'x'},
          },
          {
            'name': '小新',
            'persona_prompt': '你是小新。',
            'address_user': ['学长'],
          },
        ]) {
          expect(
            (await call(config, AssistantWriteTools.createRole, args))['error'],
            'invalid',
          );
        }
        expect(
          (await container.read(assistantRoleStoreProvider).load()).length,
          before,
        );

        final created = await call(config, AssistantWriteTools.createRole, {
          'name': '小新',
          'persona_prompt': '你是小新。',
        });
        final id = created['role_id'] as String;
        final creation = await latestChange();
        await pumpEventQueue();
        await container
            .read(conversationsProvider.notifier)
            .applyContactEdit(id, avatarUrl: 'avatar.png');
        await expectLater(undo(creation), throwsStateError);
        expect(await roleNow(id), isNotNull);
      },
    );

    test('preset switches and new roles are undoable', () async {
      final store = container.read(sillyTavernPresetStoreProvider);
      final preset = await store.importSource(r'''
{
  "prompts": [
    {"identifier":"main","name":"主提示","role":"system","content":"写得短"},
    {"identifier":"chatHistory","marker":true}
  ],
  "prompt_order": [{"order":[
    {"identifier":"main","enabled":true},
    {"identifier":"chatHistory","enabled":true}
  ]}]
}
''', sourceFileName: 'short.json');
      final config = await prepare(assistant());

      final toggled = await call(config, AssistantWriteTools.togglePresetItem, {
        'preset_id': preset.id,
        'kind': 'prompt',
        'item_id': 'main',
        'enabled': false,
      });
      expect(toggled['change'], contains('主提示'));
      expect(
        (await store.get(preset.id))!.selectedOrder.entries
            .singleWhere((e) => e.identifier == 'main')
            .enabled,
        isFalse,
      );
      await undo(await latestChange());
      expect(
        (await store.get(preset.id))!.selectedOrder.entries
            .singleWhere((e) => e.identifier == 'main')
            .enabled,
        isTrue,
      );

      final created = await call(config, AssistantWriteTools.createRole, {
        'name': '小新',
        'persona_prompt': '你是小新。',
      });
      final id = created['role_id'] as String;
      expect((await roleNow(id))!.displayName, '小新');
      expect((await roleNow(id))!.enabledPlugins, ['memory', 'time_awareness']);
      await undo(await latestChange());
      expect(await roleNow(id), isNull);
    });
  });
}
