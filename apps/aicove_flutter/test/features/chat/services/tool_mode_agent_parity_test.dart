// ADR0111: a role in tool mode gets the same abilities as AIcove酱 — the
// AIcove management plugin, every workspace on this device and the same
// tool policy. Chat-mode roles stay as they were.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:aicove_flutter/src/core/utils/token_estimator.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/providers/preset_recipe_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_backend_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/providers/memory_providers.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector.dart';
import 'package:aicove_flutter/src/features/plugins/mcp/mcp_connector_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_grants.dart';
import 'package:aicove_flutter/src/features/workspace/workspace_providers.dart';
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

class _Settings extends AppSettingsNotifier {
  _Settings(this._settings);
  final AppSettings _settings;
  @override
  Future<AppSettings> build() async => _settings;
}

final _now = DateTime.utc(2026, 10, 23, 10);
const _model = 'openai:gpt-4o';

final _appSettings = mapUiModelsToAppSettings({'context_window_tokens': 272000})
    .copyWith(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> containerFor() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('agent_parity_');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TraceStore.instance.debugResetForTest();
    final database = db.AppDatabase.forTesting(
      NativeDatabase(File('${root.path}/test.sqlite')),
    );
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appSettingsProvider.overrideWith(() => _Settings(_appSettings)),
        requestClockProvider.overrideWithValue(() => _now),
        memoryKeeperProvider.overrideWith(
          (ref) => MemoryKeeperService(
            store: ref.read(memoryStoreProvider),
            loadMessages: (_) async => const [],
            compactedBoundaries: (_) async => const {},
            agentFactory: () => throw StateError('memory agent disabled'),
            allowed: (_) async => false,
          ),
        ),
        sillyTavernPresetStoreProvider.overrideWithValue(
          SillyTavernPresetStore(documentsDirectoryResolver: () async => root),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    });
    await container.read(appSettingsProvider.future);
    return container;
  }

  Future<dynamic> prepare(
    ProviderContainer container,
    RoleAgentMode? mode, {
    String conversationId = 'user_agent',
    List<String>? plugins,
    List<Message>? history,
  }) => container
      .read(chatSendServiceProvider)
      .prepareApiConfig(
        conv: Conversation(
          id: conversationId,
          title: '小帮手',
          displayName: '小帮手',
          agentMode: mode,
          enabledPlugins: plugins,
          createdAt: _now,
          updatedAt: _now,
          messages: const [],
        ),
        history:
            history ??
            [
              Message(
                id: 'u1',
                role: 'user',
                content: '看看我的角色库',
                createdAt: _now,
              ),
            ],
        userText: '看看我的角色库',
      );

  test('tool-mode loadout size measurement', () async {
    final container = await containerFor();
    final config = await prepare(container, RoleAgentMode.tool, plugins: []);
    final schemas = jsonEncode(config.tools);
    final codemode =
        config.boundTools.firstWhere((t) => t.name == 'codemode').description
            as String;
    final prompt = AssistantRequestScope.genericPrompt(writable: true);
    expect(config.tools, hasLength(9));
    expect(prompt.length, lessThanOrEqualTo(500));
    debugPrint(
      jsonEncode({
        'direct_tools': config.tools.length,
        'schemas_chars': schemas.length,
        'schemas_estimated_tokens': estimateTokenCount(schemas),
        'codemode_chars': codemode.length,
        'codemode_estimated_tokens': estimateTokenCount(codemode),
        'assistant_prompt_chars': prompt.length,
        'assistant_prompt_estimated_tokens': estimateTokenCount(prompt),
      }),
    );
  });

  test('a user-made tool-mode role gets the AIcove management plugin, every '
      'workspace and the assistant tool policy', () async {
    final container = await containerFor();
    // A workspace no role was ever granted.
    final other = await (await container.read(
      workspaceStoreProvider.future,
    )).create(name: '别的空间');
    final config = await prepare(container, RoleAgentMode.tool);

    final tools = {for (final t in config.boundTools ?? []) t.name as String};
    expect(tools, containsAll(['aicove_list_roles', 'workspace_open']));
    expect(config.toolPolicy, isNotNull);

    final system = jsonEncode(config.messages);
    expect(system, contains('你是 AIcove 里的 Agent'));
    expect(system, isNot(contains('你是 AIcove酱')));
    expect(system, isNot(contains('<component name=')));
    expect(system, isNot(contains('## 资料库')));
    expect(system, contains('await describeTool(name)'));
    final assistant = await prepare(
      container,
      RoleAgentMode.tool,
      conversationId: kAicoveAssistantId,
    );
    expect(jsonEncode(assistant.messages), contains('<component name='));
    expect(jsonEncode(assistant.messages), contains('## 资料库'));

    final open = config.boundTools.firstWhere(
      (t) => t.name == 'workspace_open',
    );
    final opened = await open.handler({'id': defaultWorkspaceId});
    final list = config.boundTools.firstWhere(
      (t) => t.name == 'workspace_list',
    );
    final listed = await list.handler(const <String, dynamic>{});
    expect(opened, contains('name: AIcove'));
    expect(listed, contains('stickers/'));
    final openedOther = await open.handler({'id': other.id});
    expect(openedOther, contains('name: 别的空间'));
  });

  test('a chat-mode role stays without them', () async {
    final container = await containerFor();
    final config = await prepare(container, null);

    final tools = {for (final t in config.boundTools ?? []) t.name as String};
    expect(tools, isNot(contains('aicove_list_roles')));
    expect(tools, isNot(contains('workspace_open')));
    expect(config.toolPolicy, isNull);
    expect(config.tools, isNull);
    final agent = await prepare(container, RoleAgentMode.agent);
    expect(agent.boundTools.map((t) => t.name), contains('delegate_task'));
    expect(
      agent.boundTools.map((t) => t.name),
      isNot(contains('workspace_open')),
    );
  });

  test('workspace selection survives subsequent requests and stays local to '
      'one conversation', () async {
    final container = await containerFor();
    final store = await container.read(workspaceStoreProvider.future);
    final other = await store.create(name: '持续工作的空间');
    final first = await prepare(container, RoleAgentMode.tool);
    await first.boundTools.firstWhere((t) => t.name == 'workspace_open').invoke(
      {'id': other.id},
    );
    await (await SharedPreferences.getInstance()).reload();

    final second = await prepare(container, RoleAgentMode.tool);
    expect(second.currentWorkspaceId(), other.id);
    expect(jsonEncode(second.messages), contains('当前工作区：${other.id}'));
    await second.boundTools.firstWhere((t) => t.name == 'write').invoke({
      'path': 'next-turn.txt',
      'content': '继续上一轮',
    });
    expect(await store.stat(other.id, 'next-turn.txt'), isNotNull);
    expect(await store.stat(defaultWorkspaceId, 'next-turn.txt'), isNull);

    final separate = await prepare(
      container,
      RoleAgentMode.tool,
      conversationId: 'another_agent',
    );
    expect(separate.currentWorkspaceId(), defaultWorkspaceId);

    // A failed switch must not replace the remembered selection.
    final failed = await second.boundTools
        .firstWhere((t) => t.name == 'workspace_open')
        .invoke({'id': 'missing'});
    expect(failed.isError, isTrue);
    expect(
      (await prepare(container, RoleAgentMode.tool)).currentWorkspaceId(),
      other.id,
    );

    final created = await second.boundTools
        .firstWhere((t) => t.name == 'workspace_create')
        .invoke({'name': '新建后接着工作'});
    final createdId = (created.structured as Map)['workspace'];
    expect(
      (await prepare(container, RoleAgentMode.tool)).currentWorkspaceId(),
      createdId,
    );
  });

  test(
    'a remembered workspace missing on this device falls back to default',
    () async {
      final container = await containerFor();
      await (await SharedPreferences.getInstance()).setString(
        'workspace_current_user_agent',
        'not-on-this-device',
      );
      final config = await prepare(container, RoleAgentMode.tool);
      expect(config.currentWorkspaceId(), defaultWorkspaceId);
      expect(jsonEncode(config.messages), contains('当前工作区：aicove'));
    },
  );

  test(
    'native cwd survives requests, stays conversation-local and recovers when missing',
    () async {
      final container = await containerFor();
      final project = await Directory.systemTemp.createTemp('native-role-cwd-');
      addTearDown(() async {
        if (await project.exists()) await project.delete(recursive: true);
      });
      final first = await prepare(container, RoleAgentMode.tool);
      final opened = await first.boundTools
          .firstWhere((t) => t.name == 'workspace_open')
          .invoke({'path': project.path});
      expect(opened.isError, false, reason: opened.text);
      final canonical = await project.resolveSymbolicLinks();
      final second = await prepare(container, RoleAgentMode.tool);
      expect(jsonEncode(second.messages), contains('当前工作区：$canonical'));
      expect(second.currentWorkspaceId(), canonical);
      final written = await second.boundTools
          .firstWhere((t) => t.name == 'write')
          .invoke({'path': 'native.txt', 'content': 'native'});
      expect(written.isError, false, reason: written.text);
      expect(await File('${project.path}/native.txt').readAsString(), 'native');
      final another = await prepare(
        container,
        RoleAgentMode.tool,
        conversationId: 'another_native_agent',
      );
      expect(jsonEncode(another.messages), contains('当前工作区：aicove'));
      await project.delete(recursive: true);
      final fallback = await prepare(container, RoleAgentMode.tool);
      expect(
        jsonEncode(fallback.messages),
        allOf(contains('已不可用'), contains('已切回默认空间')),
      );
      expect(fallback.currentWorkspaceId(), 'aicove');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'workspace_current_user_agent_local',
        ),
        isNull,
      );
    },
  );

  test(
    'provider schemas are compact while scripts retain atomic tools',
    () async {
      final container = await containerFor();
      final config = await prepare(container, RoleAgentMode.tool, plugins: []);
      final names = {
        for (final schema in config.tools) schema['function']['name'],
      };
      expect(names, {
        'read',
        'write',
        'edit',
        'workspace_search',
        'workspace_open',
        'bash',
        'codemode',
        'aicove_role',
        'aicove_role_context',
      });
      final bound = {for (final tool in config.boundTools) tool.name: tool};
      const atomic = [
        'workspace_create',
        'workspace_list',
        'workspace_glob',
        'workspace_grep',
        'read_tool_result',
        'aicove_list_roles',
        'aicove_read_role',
        'aicove_update_role',
        'aicove_create_role',
        'aicove_read_role_chat',
        'aicove_append_role_chat',
        'aicove_update_role_chat',
        'aicove_delete_role_chat',
        'aicove_read_role_summary',
        'aicove_write_role_summary',
        'aicove_delete_role_summary',
        'aicove_read_role_memory',
        'aicove_write_role_memory',
        'aicove_delete_role_memory',
      ];
      for (final name in atomic) {
        expect(bound[name], isNotNull, reason: name);
        expect(
          bound[name].exposure.toString(),
          endsWith('.codemode'),
          reason: name,
        );
      }
    },
  );

  test(
    'raw ToolBlock history carries only granted MCP tools into the next request',
    () async {
      final container = await containerFor();
      final notifier = container.read(mcpConnectorsConfigProvider.notifier);
      await notifier.ready;
      await notifier.saveConnector(
        const McpConnector(
          id: 'notes',
          url: 'https://invalid.test/mcp',
          tools: [McpToolInfo(name: 'lookup', description: '查询笔记')],
        ),
      );
      final fresh = await prepare(
        container,
        RoleAgentMode.tool,
        plugins: ['mcp:notes'],
      );
      Set<String> names(dynamic config) => {
        for (final schema in config.tools) schema['function']['name'] as String,
      };
      expect(names(fresh), contains('tool_search'));
      expect(names(fresh), isNot(contains('mcp__notes__lookup')));
      final initialSchemas = jsonEncode(fresh.tools);
      fresh.onToolSchemasChanged(<Map<String, dynamic>>[
        ...fresh.tools,
        fresh.boundTools
            .firstWhere((tool) => tool.name == 'mcp__notes__lookup')
            .toOpenAISchema(),
      ]);
      expect(
        jsonEncode(fresh.tools),
        initialSchemas,
        reason:
            'runtime budgeting must not persist search-only activations in a reusable config',
      );
      final history = [
        Message(id: 'u1', role: 'user', content: '查询笔记', createdAt: _now),
        Message(
          id: 'a1',
          role: 'assistant',
          content: '',
          createdAt: _now,
          blocks: [
            ToolBlock(
              messageId: 'a1',
              toolName: 'mcp__notes__lookup',
              toolCallId: 'old',
              arguments: {},
              result: {'text': '找到笔记'},
            ),
          ],
        ),
        Message(id: 'u2', role: 'user', content: '接着查', createdAt: _now),
      ];
      final continued = await prepare(
        container,
        RoleAgentMode.tool,
        plugins: ['mcp:notes'],
        history: history,
      );
      expect(names(continued), contains('mcp__notes__lookup'));
      final legacy = await prepare(
        container,
        RoleAgentMode.tool,
        plugins: ['mcp:notes'],
        history: [
          Message(
            id: 'legacy',
            role: 'assistant',
            content: '',
            createdAt: _now,
            blocks: [
              ToolBlock(
                messageId: 'legacy',
                toolName: 'mcp__notes__lookup',
                result: {'text': '旧工具记录'},
              ),
            ],
          ),
          history.last,
        ],
      );
      expect(names(legacy), contains('mcp__notes__lookup'));
      final revoked = await prepare(
        container,
        RoleAgentMode.tool,
        plugins: [],
        history: history,
      );
      expect(names(revoked), isNot(contains('mcp__notes__lookup')));
      expect(names(revoked), isNot(contains('tool_search')));
    },
  );
}
