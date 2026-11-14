// ADR0111: a role in tool mode gets the same abilities as AIcove酱 — the
// AIcove management plugin, every workspace on this device and the same
// tool policy. Chat-mode roles stay as they were.
import 'dart:convert';
import 'dart:io';
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

  Set<String> toolNames(dynamic config) => {
    for (final schema in config.tools ?? const [])
      schema['function']['name'] as String,
  };

  test('legacy modes do not grant tools without active capabilities', () async {
    final container = await containerFor();
    for (final mode in [null, RoleAgentMode.chat, RoleAgentMode.agent]) {
      for (final plugins in [
        <String>[],
        ['image'],
        ['web_search'],
        ['mcp:missing'],
      ]) {
        final config = await prepare(container, mode, plugins: plugins);
        expect(config.tools, isNull, reason: '$mode / $plugins');
        expect(config.boundTools, isEmpty);
        expect(config.toolPolicy, isNull);
      }
    }
  });

  test(
    'assistant capability routes all roles without leaking management or workspace tools',
    () async {
      final container = await containerFor();
      for (final mode in [
        null,
        RoleAgentMode.chat,
        RoleAgentMode.agent,
        RoleAgentMode.tool,
      ]) {
        final config = await prepare(
          container,
          mode,
          plugins: ['aicove_assistant'],
        );
        expect(toolNames(config), {'delegate_task'});
        expect(config.boundTools.map((t) => t.name).toSet(), {
          'delegate_task',
        });
        expect(config.toolPolicy, isNull);
        final prompt = jsonEncode(config.messages);
        expect(prompt, contains('AIcove 软件管理能力'));
        expect(prompt, isNot(contains('<component name=')));
        expect(prompt, isNot(contains('## 资料库')));
        expect(prompt, isNot(contains('await describeTool(name)')));
      }
      final builtin = await prepare(
        container,
        null,
        conversationId: kAicoveAssistantId,
        plugins: [],
      );
      expect(toolNames(builtin), {'delegate_task'});
      expect(jsonEncode(builtin.messages), contains('<component name='));
    },
  );

  test(
    'configured MCP routes through delegate_task and never leaks historical tools',
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
      final config = await prepare(
        container,
        null,
        plugins: ['mcp:notes'],
        history: [
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
                result: {'text': '笔记'},
              ),
            ],
          ),
          Message(id: 'u2', role: 'user', content: '继续', createdAt: _now),
        ],
      );
      expect(toolNames(config), {'delegate_task'});
      expect(
        config.boundTools.map((t) => t.name),
        isNot(contains('mcp__notes__lookup')),
      );
      expect((await prepare(container, null, plugins: [])).tools, isNull);
    },
  );

  test('MCP with every tool disabled does not activate routing', () async {
    final container = await containerFor();
    final notifier = container.read(mcpConnectorsConfigProvider.notifier);
    await notifier.ready;
    await notifier.saveConnector(
      const McpConnector(
        id: 'notes',
        url: 'https://invalid.test/mcp',
        tools: [McpToolInfo(name: 'lookup')],
        disabledTools: {'lookup'},
      ),
    );
    expect(
      (await prepare(container, null, plugins: ['mcp:notes'])).tools,
      isNull,
    );
  });

  test('only local workspace grants activate the router', () async {
    final container = await containerFor();
    final workspace = await (await container.read(
      workspaceStoreProvider.future,
    )).create(name: '授权的工作区');
    final config = await prepare(
      container,
      null,
      plugins: [WorkspaceGrants.pluginIdOf(workspace.id)],
    );
    expect(toolNames(config), {'delegate_task'});
    final missing = await prepare(
      container,
      null,
      plugins: [WorkspaceGrants.pluginIdOf('missing')],
    );
    expect(missing.tools, isNull);
  });
}
