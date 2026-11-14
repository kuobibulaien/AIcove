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
    show
        GateDecision,
        GateOutcome,
        KernelToolCall,
        ToolCallScope,
        ToolEffect,
        KernelCancellation;
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
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
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/plugins/packages/package_providers.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
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
  void resumeOnce(String ownerId, {DateTime? now}) => resumed.add(ownerId);
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
        _model: const ModelConfig(chatCapabilities: ['tools']),
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

  Future<ApiConfig> foreground(Conversation conv) => container
      .read(chatSendServiceProvider)
      .prepareApiConfig(conv: conv, history: _history, userText: '帮我看看');

  Future<ApiConfig> prepare(Conversation conv, {bool readOnly = false}) async {
    final cancellation = KernelCancellation();
    final provider = Provider(
      (ref) => resolveConversationTaskCapabilities(
        ref,
        conv,
        instruction: '帮我看看',
        runId: 'assistant-test',
        cancellation: cancellation,
        readOnly: readOnly,
      ),
    );
    final capabilities = await container.read(provider);
    late ApiConfig captured;
    final runner = TaskAgentRunner(
      loadSettings: () => container.read(appSettingsProvider.future),
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            captured = config.copyWith(boundTools: tools);
            return const ApiCallResult(
              replyText: 'done',
              processedText: 'done',
              pluginEvents: [],
              toolResults: [],
            );
          },
    );
    await runner.run(
      taskId: 'assistant-test',
      runId: 'assistant-test',
      conversationId: conv.id,
      transcript: '帮我看看',
      readOnly: readOnly,
      capabilities: capabilities,
      preset: const TaskAgentPreset(),
      cancellation: cancellation,
    );
    return captured;
  }

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

  test(
    'foreground routes tasks; only capable background runs get management tools',
    () async {
      final front = await foreground(assistant());
      expect(toolsOf(front), contains('delegate_task'));
      expect(jsonEncode(front.messages), contains('<component name='));
      expect(jsonEncode(front.messages), isNot(contains('aicove_list_roles')));
      expect(
        front.boundTools!.where((t) => t.name.startsWith('aicove_')),
        isEmpty,
      );
      final own = await prepare(assistant());
      final other = await prepare(_role('role_li'));

      expect(
        own.boundTools!
            .where((t) => t.exposure == ToolExposure.codemode)
            .map((t) => t.name),
        containsAll(['aicove_docs_read', 'aicove_inspect_context']),
      );
      expect(toolsOf(own), contains('codemode'));
      expect(
        toolsOf(own),
        containsAll([
          'aicove_role',
          'aicove_role_context',
          'ask_user',
          'submit_reference_material',
        ]),
      );
      expect(jsonEncode(own.tools), contains('aicove_inspect_context'));
      expect(
        other.boundTools?.where((t) => t.name.startsWith('aicove_')) ?? [],
        isEmpty,
      );
      expect(toolsOf(other).where((t) => t.startsWith('aicove_')), isEmpty);
      expect(jsonEncode(other.messages), isNot(contains('住在 AIcove 里的小管家')));
    },
  );

  test(
    'other roles with management enabled only get routing guidance',
    () async {
      final role = _role(
        'role_li',
      ).copyWith(enabledPlugins: const ['aicove_assistant']);
      final config = await foreground(role);
      final prompt = jsonEncode(config.messages);
      expect(toolsOf(config), contains('delegate_task'));
      expect(prompt, contains('## AIcove 软件管理能力'));
      expect(prompt, contains('交给后台执行'));
      expect(prompt, isNot(contains('<component name=')));
    },
  );

  test('read-only backend exposes role reads and no write or shell tools', () async {
    final config = await prepare(assistant(), readOnly: true);
    expect(config.boundTools!.where((tool) => tool.effect == ToolEffect.write), isEmpty);
    expect(config.boundTools!.map((tool) => tool.name), isNot(contains('bash')));
    final role = config.boundTools!.singleWhere((tool) => tool.name == 'aicove_role');
    expect((role.parameterSchema['properties'] as Map)['action']['enum'], ['list', 'read']);
    expect(role.effect, ToolEffect.readPrivate);
    expect((await call(config, 'aicove_role', {'action': 'create'}))['message'], contains('只读'));
  });

  test(
    'aggregate role card preserves read-only access and atomic contracts',
    () async {
      final readOnly = container.read(assistantToolsetProvider).roleTool();
      expect(readOnly.effect, ToolEffect.readPrivate);
      expect(
        (readOnly.parameterSchema['properties'] as Map)['action']['enum'],
        ['list', 'read'],
      );
      expect(
        jsonDecode((await readOnly.handler({'action': 'create'}))!)['message'],
        contains('只读'),
      );
      expect(
        jsonDecode((await readOnly.handler({'action': 'read'}))!)['error'],
        'invalid',
      );
      final config = await prepare(assistant());
      expect(
        await call(config, 'aicove_role', {'action': 'list'}),
        await call(config, 'aicove_list_roles'),
      );
      expect(
        await call(config, 'aicove_role', {
          'action': 'read',
          'role_id': 'role_li',
        }),
        await call(config, 'aicove_read_role', {'role_id': 'role_li'}),
      );
      expect(
        (await call(config, 'aicove_role', {
          'action': 'create',
          'name': 'incomplete',
        }))['error'],
        'invalid',
      );
    },
  );

  test(
    'aggregate role card uses original risk, confirmation and journal',
    () async {
      final config = await prepare(assistant());
      final writes = container.read(assistantWriteToolsProvider);
      final risk = AssistantRequestScope.riskOf(
        container.read(assistantToolsetProvider),
        writes,
      );
      for (final action in ['list', 'read', 'create', 'update']) {
        final args = <String, dynamic>{
          'action': action,
          'role_id': 'role_li',
          'name': '聚合角色',
          'persona_prompt': '原始设定',
        };
        expect(
          risk('aicove_role', args),
          action == 'list' || action == 'read'
              ? AssistantRisk.readOnly
              : AssistantRisk.review,
        );
        expect(writes.riskOf('aicove_role', args), risk('aicove_role', args));
        final prompt = writes.describe('aicove_role', args);
        final original = writes.describe(
          AssistantWriteTools.roleToolName(action)!,
          AssistantWriteTools.roleArguments(args),
        );
        expect(prompt.title, original.title);
        expect(prompt.detail, original.detail);
      }
      await container.read(assistantAlwaysAskProvider.notifier).set(true);
      for (final action in ['read', 'update']) {
        final verdict = config.toolPolicy!.gate.check(
          KernelToolCall(
            id: action,
            name: 'aicove_role',
            arguments: {'action': action, 'role_id': 'role_li'},
          ),
          ToolEffect.write,
        );
        expect(
          verdict.decision,
          action == 'read' ? GateDecision.allow : GateDecision.ask,
        );
      }
      final created = await call(config, 'aicove_role', {
        'action': 'create',
        'name': '聚合角色',
        'persona_prompt': '原始设定',
      });
      expect(created['ok'], true);
      final id = created['role_id'];
      expect(id, isA<String>());
      final changed = await call(config, 'aicove_role', {
        'action': 'update',
        'role_id': id,
        'persona_prompt_replace': {'old_text': '原始', 'new_text': '更新'},
      });
      expect(changed['ok'], true);
      final read = await call(config, 'aicove_role', {
        'action': 'read',
        'role_id': id,
      });
      expect(read['persona_prompt'], '更新设定');
      final entry = (await container.read(
        assistantRecentChangesProvider.future,
      )).first;
      await container.read(assistantChangeJournalProvider).undo(entry.id);
      expect(
        (await call(config, 'aicove_role', {
          'action': 'read',
          'role_id': id,
        }))['persona_prompt'],
        '原始设定',
      );
    },
  );

  test('roles in the privacy space stay invisible', () async {
    final config = await prepare(assistant());
    final listed = await call(config, 'aicove_list_roles');
    final ids = [for (final r in listed['roles'] as List) (r as Map)['id']];
    expect(ids, contains('role_li'));
    expect(ids, isNot(contains('role_secret')));

    final card = await call(config, 'aicove_read_role', {'role_id': 'role_li'});
    expect(card['persona_prompt'], _personaText);
    expect(card, isNot(contains('agent_mode')));
    expect(card['has_assistant_capability'], isFalse);
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

    await foreground(_role('role_li'));
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

    Future<void> installExtensions() async {
      await container.read(aicovePackagesProvider.notifier).importFiles({
        'SKILL.md': utf8.encode(
          '---\nname: local-skill\ndescription: A local skill\n---\nUse locally.',
        ),
      });
      await container
          .read(mcpConnectorsConfigProvider.notifier)
          .saveConnector(
            const McpConnector(
              id: 'local',
              name: '本地连接器',
              url: 'https://example.com/mcp',
              bearerToken: 'secret-token',
              headers: {'X-Secret': 'secret-header'},
              enabled: false,
            ),
          );
    }

    Future<Map<String, dynamic>> allowedPluginCall(
      ApiConfig config,
      Map<String, dynamic> args,
    ) => ToolCallScope().run(() async {
      final verdict = config.toolPolicy!.gate.check(
        KernelToolCall(
          id: 'plugins',
          name: AssistantWriteTools.setRolePlugins,
          arguments: {'role_id': 'role_li', ...args},
        ),
        ToolEffect.write,
      );
      expect(verdict.decision, GateDecision.allow);
      ToolCallScope.current!.outcome = GateOutcome.allowed;
      return call(config, AssistantWriteTools.setRolePlugins, {
        'role_id': 'role_li',
        ...args,
      });
    });

    test(
      'installed packages and configured MCP can be discovered, enabled and undone',
      () async {
        final config = await prepare(assistant());
        // The toolset must not freeze the catalog at request assembly.
        await installExtensions();
        final listed = await call(config, 'aicove_list_available_plugins');
        final entries = (listed['plugins'] as List).cast<Map>();
        expect(
          entries.map((e) => e['plugin_id']),
          containsAll([
            ...kAssistantRolePlugins.keys,
            'pkg:local-skill',
            'mcp:local',
          ]),
        );
        final mcp = entries.singleWhere((e) => e['plugin_id'] == 'mcp:local');
        expect(mcp['name'], '本地连接器');
        expect(mcp['usable'], isFalse);
        expect(jsonEncode(listed), isNot(contains('secret-token')));
        expect(jsonEncode(listed), isNot(contains('secret-header')));
        expect(
          config.toolPolicy!.gate
              .check(
                const KernelToolCall(
                  id: 'list',
                  name: 'aicove_list_available_plugins',
                ),
                ToolEffect.readPrivate,
              )
              .decision,
          GateDecision.allow,
        );
        final before = (await roleNow('role_li'))!.enabledPlugins;
        final result = await allowedPluginCall(config, {
          'plugins': ['memory', 'pkg:local-skill', 'mcp:local'],
        });
        expect(result['ok'], isTrue);
        expect((await roleNow('role_li'))!.enabledPlugins, [
          'memory',
          'pkg:local-skill',
          'mcp:local',
        ]);
        // Enabling changes the next request, not the already assembled run.
        expect(
          config.boundTools!.map((t) => t.name),
          isNot(contains('read_skill_local-skill')),
        );
        final next = await prepare((await roleNow('role_li'))!);
        expect(
          next.boundTools!.map((t) => t.name),
          contains('read_skill_local-skill'),
        );
        await undo(await latestChange());
        expect((await roleNow('role_li'))!.enabledPlugins, before);
        final disabled = await prepare((await roleNow('role_li'))!);
        expect(
          disabled.boundTools!.map((t) => t.name),
          isNot(contains('read_skill_local-skill')),
        );
      },
    );

    test(
      'plugin replacement preserves grants and legacy calls; extensions can be cleared',
      () async {
        await installExtensions();
        await container
            .read(conversationsProvider.notifier)
            .applyContactEdit(
              'role_li',
              enabledPlugins: [
                'memory',
                'pkg:local-skill',
                'mcp:local',
                'ws:local',
              ],
            );
        final config = await prepare(assistant());
        await allowedPluginCall(config, {
          'plugins': ['image'],
        });
        expect((await roleNow('role_li'))!.enabledPlugins, [
          'image',
          'pkg:local-skill',
          'mcp:local',
          'ws:local',
        ]);
        await allowedPluginCall(config, {'all': true});
        expect(
          (await roleNow('role_li'))!.enabledPlugins,
          containsAll([
            ...kAssistantRolePlugins.keys.where(
              (id) => id != 'aicove_assistant',
            ),
            'pkg:local-skill',
            'mcp:local',
            'ws:local',
          ]),
        );
        await allowedPluginCall(config, {
          'all': true,
          'plugins': ['pkg:local-skill'],
        });
        expect((await roleNow('role_li'))!.enabledPlugins, [
          ...kAssistantRolePlugins.keys.where((id) => id != 'aicove_assistant'),
          'pkg:local-skill',
          'ws:local',
        ]);
        await allowedPluginCall(config, {
          'plugins': ['memory'],
          'extensions': [],
        });
        expect((await roleNow('role_li'))!.enabledPlugins, [
          'memory',
          'ws:local',
        ]);
        await allowedPluginCall(config, {
          'plugins': ['memory'],
          'extensions': ['mcp:local'],
        });
        expect((await roleNow('role_li'))!.enabledPlugins, [
          'memory',
          'mcp:local',
          'ws:local',
        ]);
        await allowedPluginCall(config, {'extensions': []});
        expect((await roleNow('role_li'))!.enabledPlugins, [
          'memory',
          'ws:local',
        ]);
      },
    );

    test(
      'extension validation also applies to all=true and explicit extension lists',
      () async {
        final config = await prepare(assistant());
        for (final args in [
          {
            'all': true,
            'plugins': ['mcp:evil'],
          },
          {'all': true, 'plugins': 'memory'},
          {
            'plugins': ['pkg:missing'],
          },
          {
            'extensions': ['mcp:evil'],
          },
          {
            'extensions': ['ws:new'],
          },
          {
            'extensions': ['memory'],
          },
          {'extensions': 'mcp:local'},
          {
            'plugins': ['memory'],
            'extensions': [null],
          },
          {
            'plugins': ['ws:new'],
          },
        ]) {
          expect(
            (await allowedPluginCall(config, args))['error'],
            'invalid',
            reason: '$args',
          );
        }
      },
    );

    test(
      'new explicit extensions are major even when standard plugins were all enabled',
      () async {
        await installExtensions();
        final config = await prepare(assistant());
        await allowedPluginCall(config, {'all': true});
        await pumpEventQueue();
        final writes = container.read(assistantWriteToolsProvider);
        for (final id in ['pkg:local-skill', 'mcp:local']) {
          final args = {
            'role_id': 'role_li',
            'extensions': [id],
          };
          expect(
            writes.riskOf(AssistantWriteTools.setRolePlugins, args),
            AssistantRisk.major,
          );
          await container.read(assistantAlwaysAskProvider.notifier).set(true);
          expect(
            config.toolPolicy!.gate
                .check(
                  KernelToolCall(
                    id: id,
                    name: AssistantWriteTools.setRolePlugins,
                    arguments: args,
                  ),
                  ToolEffect.write,
                )
                .decision,
            GateDecision.ask,
          );
          expect(
            writes.describe(AssistantWriteTools.setRolePlugins, args).detail,
            contains(id == 'mcp:local' ? '本地连接器' : 'local-skill'),
          );
        }
        await container.read(assistantAlwaysAskProvider.notifier).set(false);
        await allowedPluginCall(config, {
          'extensions': ['pkg:local-skill', 'mcp:local'],
        });
        await pumpEventQueue();
        expect(
          writes.riskOf(AssistantWriteTools.setRolePlugins, {
            'role_id': 'role_li',
            'extensions': ['mcp:local'],
          }),
          AssistantRisk.reversible,
        );
      },
    );

    test(
      'extension approval is call-scoped and removed catalog entries are rejected',
      () async {
        await installExtensions();
        final config = await prepare(assistant());
        final writes = container.read(assistantWriteToolsProvider);
        final args = {
          'role_id': 'role_li',
          'extensions': ['pkg:local-skill'],
        };
        final scope = ToolCallScope();
        scope.run(
          () => writes.riskOf(AssistantWriteTools.setRolePlugins, args),
        );
        scope.outcome = GateOutcome.allowed;
        expect(
          (await scope.run(
            () => call(config, AssistantWriteTools.setRolePlugins, args),
          ))['error'],
          'invalid',
        );
        scope.outcome = GateOutcome.approved;
        expect(
          (await scope.run(
            () => call(config, AssistantWriteTools.setRolePlugins, args),
          ))['ok'],
          isTrue,
        );
        await undo(await latestChange());
        await container
            .read(aicovePackagesProvider.notifier)
            .delete('local-skill');
        await container
            .read(mcpConnectorsConfigProvider.notifier)
            .removeConnector('local');
        for (final id in ['pkg:local-skill', 'mcp:local']) {
          expect(
            (await allowedPluginCall(config, {
              'extensions': [id],
            }))['error'],
            'invalid',
          );
        }
        await container.read(assistantAlwaysAskProvider.notifier).set(true);
        expect(
          config.toolPolicy!.gate
              .check(
                const KernelToolCall(
                  id: 'list',
                  name: 'aicove_list_available_plugins',
                ),
                ToolEffect.readPrivate,
              )
              .decision,
          GateDecision.allow,
        );
      },
    );

    test('software management and model are persisted and undoable', () async {
      final config = await prepare(assistant());
      expect((await roleNow('role_li'))!.agentMode, isNull);
      final result = await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_li',
        'enabled_plugins': ['memory', 'time_awareness', 'aicove_assistant'],
        'model_override': 'openai:gpt-4o',
      });
      expect(result['ok'], isTrue, reason: '$result');
      var role = (await roleNow('role_li'))!;
      expect(role.agentMode, isNull);
      expect(role.hasAssistantCapability, isTrue);
      expect(role.sessionProvider, 'openai:gpt-4o');
      expect(role.chatDisplayStyle, isNull);
      final first = await latestChange();
      await undo(first);
      role = (await roleNow('role_li'))!;
      expect(
        role.agentMode,
        isNull,
        reason: 'undo restores the raw nullable field',
      );
      expect(role.sessionProvider, isNull);
      await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_li',
        'model_override': 'openai:custom:model',
      });
      await call(config, AssistantWriteTools.updateRole, {
        'role_id': 'role_li',
        'model_override': '',
      });
      expect((await roleNow('role_li'))!.sessionProvider, isNull);
      await undo(await latestChange());
      expect(
        (await roleNow('role_li'))!.sessionProvider,
        'openai:custom:model',
      );
    });

    test(
      'new roles use bubbles and reject retired modes or invalid models',
      () async {
        final config = await prepare(assistant());
        final created = await call(config, AssistantWriteTools.createRole, {
          'name': '工具角色',
          'persona_prompt': '帮忙工作',
          'enabled_plugins': ['memory', 'time_awareness', 'aicove_assistant'],
          'model_override': 'openai:gpt-4o',
        });
        expect(created['ok'], isTrue);
        final role = (await roleNow(created['role_id'] as String))!;
        expect(role.agentMode, isNull);
        expect(role.hasAssistantCapability, isTrue);
        expect(role.chatDisplayStyle, ChatDisplayStyle.bubble);
        expect(role.sessionProvider, 'openai:gpt-4o');
        await undo(await latestChange());
        expect(await roleNow(role.id), isNull);
        final count =
            (await container.read(assistantRoleStoreProvider).load()).length;
        for (final bad in [
          {'agent_mode': 'invalid'},
          {'agent_mode': ''},
          {'agent_mode': null},
          {'enabled_plugins': null},
          {
            'enabled_plugins': ['unknown'],
          },
          {'model_override': 123},
          {'model_override': 'no-colon'},
          {'model_override': ':model'},
          {'model_override': 'openai:'},
        ]) {
          expect(
            (await call(config, AssistantWriteTools.createRole, {
              'name': '不能创建',
              'persona_prompt': 'x',
              ...bad,
            }))['error'],
            'invalid',
            reason: '$bad',
          );
          expect(
            (await call(config, AssistantWriteTools.updateRole, {
              'role_id': 'role_li',
              ...bad,
            }))['error'],
            'invalid',
            reason: '$bad',
          );
        }
        expect(
          (await container.read(assistantRoleStoreProvider).load()).length,
          count,
        );
        expect(
          (await call(config, AssistantWriteTools.updateRole, {
            'role_id': kAicoveAssistantId,
            'agent_mode': 'chat',
          }))['error'],
          'invalid',
        );
        expect(
          (await call(config, AssistantWriteTools.updateRole, {
            'role_id': kAicoveAssistantId,
            'agent_mode': 'agent',
          }))['error'],
          'invalid',
        );
        expect(
          (await roleNow(kAicoveAssistantId))!.effectiveAgentMode,
          RoleAgentMode.tool,
        );
      },
    );

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
      expect(toolsOf(own), contains(AssistantWriteTools.roleTool));
      expect(toolsOf(own), isNot(contains(AssistantWriteTools.updateRole)));
      expect(own.toolPolicy!.gate, isA<AssistantToolGate>());
      expect(decide('aicove_read_role'), GateDecision.allow);
      expect(decide(AssistantWriteTools.togglePresetItem), GateDecision.allow);
      expect(decide(AssistantWriteTools.updateRole), GateDecision.allow);
      expect(
        other.boundTools?.where((t) => t.name.startsWith('aicove_')) ?? [],
        isEmpty,
      );
      expect(other.toolPolicy!.gate, isNot(isA<AssistantToolGate>()));
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
      expect((await roleNow(id))!.chatDisplayStyle, ChatDisplayStyle.bubble);
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
        expect(
          (await roleNow('role_li'))!.enabledPlugins,
          unorderedEquals(
            kAssistantRolePlugins.keys.where((id) => id != 'aicove_assistant'),
          ),
        );
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
