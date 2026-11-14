import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/agent_plugins/plugin_response.dart';
import 'package:aicove_flutter/src/features/agent_context/domain/agent_runtime_contracts.dart';
import 'package:aicove_flutter/src/features/agent_plugins/tool_policy.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_approvals.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_plugin.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/background_agent/background_agent_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/role_agent_mode.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/plugins/domain/handlers/ai_tool.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/task_agent/application/task_agent_runner.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/features/workspace/domain/workspace_grants.dart';
import 'package:aicove_flutter/src/features/workspace/workspace_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_reliability_regression_test.dart' show resolve;

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

class _Conversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => [];
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => _settings;
}

final _settings = mapUiModelsToAppSettings({}).copyWith(
  providers: const [
    ProviderAuth(
      id: 'test',
      apiKeys: ['test-secret'],
      apiBaseUrl: 'https://invalid.test',
    ),
  ],
);

class _History extends ChatHistoryStore {
  _History(super.ref);
  List<Message> messages = [
    for (var i = 0; i < 8; i++)
      Message(
        id: 'u$i',
        role: 'user',
        content: '用户要求$i',
        createdAt: DateTime(2026),
      ),
    Message(
      id: 'assistant',
      role: 'assistant',
      content: '助手自行决定删掉资料',
      createdAt: DateTime(2026),
    ),
  ];

  @override
  Future<List<Message>> loadCanonicalContextMessages(
    String conversationId, {
    int limit = 30,
  }) async => messages;
}

class _ReviewRunner implements ApiRunner {
  ApiConfig? config;
  List<AITool>? tools;

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<PluginResponseProcessor> responseProcessors,
    List<AITool>? availableTools,
    dynamic turnId,
    dynamic trace,
    dynamic onToolExecuting,
    bool enableStreaming = false,
    dynamic onStreamTextDelta,
    dynamic onStreamTextReset,
    dynamic onStreamToolCallObserved,
    dynamic onStreamingFallback,
    dynamic traceContext,
    KernelCancellation? cancellation,
  }) async {
    this.config = config;
    tools = availableTools;
    return const ApiCallResult(
      replyText: '{"verdict":"allow","reason":"用户要求"}',
      processedText: '',
      pluginEvents: [],
      toolResults: [],
    );
  }
}

Conversation _role(String id, List<String>? plugins) => Conversation(
  id: id,
  title: id,
  displayName: id,
  personaPrompt: '',
  messages: const [],
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  enabledPlugins: plugins,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late Directory root;
  late db.AppDatabase database;
  late PathProviderPlatform oldPaths;
  late _ReviewRunner reviewer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('batch2_policy_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.absolute.path);
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    reviewer = _ReviewRunner();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        conversationsProvider.overrideWith(_Conversations.new),
        appSettingsProvider.overrideWith(_Settings.new),
        backgroundApiRunnerProvider.overrideWithValue(reviewer),
        chatHistoryStoreProvider.overrideWith(_History.new),
      ],
    );
  });

  tearDown(() async {
    await pumpEventQueue();
    container.dispose();
    await database.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  Future<TaskAgentCapabilities> capabilities(Conversation role) =>
      container.read(
        FutureProvider(
          (ref) => resolveConversationTaskCapabilities(
            ref,
            role,
            instruction: '帮我调整设置',
            runId: 'run',
            cancellation: KernelCancellation(),
          ),
        ).future,
      );

  test(
    'assistant backend mounts full management tools and uses all local workspaces',
    () async {
      final store = await container.read(workspaceStoreProvider.future);
      final other = await store.create(name: '别的空间');
      final full = await capabilities(_role('manager', [assistantPluginId]));
      expect(full.isEmpty, isFalse);
      expect(full.prompts.keys, contains(assistantPluginId));
      expect(full.toolOwners['aicove_role'], assistantPluginId);
      expect(full.toolOwners['aicove_settings_set'], assistantPluginId);
      expect(
        full.tools.map((tool) => tool.name),
        contains('aicove_inspect_context'),
      );
      expect(full.workspaces!.workspaceIds, contains(other.id));
      expect(
        full.workspaces!.shellEnvironment!(),
        containsPair('AICOVE_KEY_TEST', 'test-secret'),
      );
      expect(full.toolPolicyFactory, isNotNull);
      final opened = await full.workspaces!
          .tools()
          .firstWhere((t) => t.name == 'workspace_open')
          .invoke({'id': other.id});
      expect(opened.text, contains('别的空间'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('workspace_current_manager'), other.id);
      await full.workspaces!.onLocalDirectoryChanged!(root.absolute.path);
      expect(
        prefs.getString('workspace_current_manager_local'),
        root.absolute.path,
      );
      await full.workspaces!.onLocalDirectoryChanged!(null);
      expect(prefs.getString('workspace_current_manager_local'), isNull);

      final ordinary = await capabilities(_role('ordinary', []));
      expect(ordinary.prompts, isNot(contains(assistantPluginId)));
      expect(ordinary.toolOwners.values, isNot(contains(assistantPluginId)));
      expect(ordinary.workspaces!.workspaceIds, isNot(contains(other.id)));
      expect(ordinary.workspaces!.shellEnvironment!(), isEmpty);
      expect(ordinary.toolPolicyFactory, isNull);

      final granted = await capabilities(
        _role('granted', [WorkspaceGrants.pluginIdOf(other.id)]),
      );
      expect(granted.workspaces!.workspaceIds, contains(other.id));
      expect(granted.workspaces!.shellEnvironment!(), isEmpty);

      // The built-in assistant retains its capability when its plugin list is narrowed.
      final builtin = await capabilities(_role(kAicoveAssistantId, []));
      expect(builtin.toolPolicyFactory, isNotNull);
      expect(builtin.workspaces!.workspaceIds, contains(other.id));
    },
  );

  test(
    'background policy retains runtime confirmation and the reviewer model',
    () async {
      final caps = await capabilities(_role('manager', [assistantPluginId]));
      ApiConfig? captured;
      final runner = TaskAgentRunner(
        loadSettings: () async => _settings,
        requestConfig: resolve,
        executor:
            ({
              required config,
              required tools,
              required sessionId,
              required cancellation,
            }) async {
              captured = config;
              return const ApiCallResult(
                replyText: '完成',
                processedText: '完成',
                pluginEvents: [],
                toolResults: [],
              );
            },
      );
      await runner.run(
        taskId: 'task',
        runId: 'run',
        transcript: '帮我调整设置',
        capabilities: caps,
        preset: const TaskAgentPreset(),
        cancellation: KernelCancellation(),
      );
      final config = captured!;
      final policy = config.toolPolicy!;
      expect(policy.customGate, isA<AssistantToolGate>());
      expect(policy.approvals, isA<AssistantApprovalPort>());
      expect(policy.approvalTimeout, const Duration(minutes: 5));
      const call = KernelToolCall(
        id: 'shell',
        name: 'bash',
        arguments: {'command': 'echo ok'},
      );
      expect(
        policy.gate.check(call, ToolEffect.external).decision,
        GateDecision.allow,
      );
      await container.read(assistantAlwaysAskProvider.notifier).set(true);
      expect(
        policy.gate.check(call, ToolEffect.external).decision,
        GateDecision.ask,
      );
      const read = KernelToolCall(
        id: 'read',
        name: 'aicove_docs_read',
        arguments: {},
      );
      expect(
        policy.gate.check(read, ToolEffect.readDiagnostic).decision,
        GateDecision.allow,
      );

      final withdrawn = Completer<void>();
      final approval = policy.approvals!.request(
        ApprovalRequest(
          toolName: 'bash',
          arguments: const {'command': 'echo ok'},
          effect: ToolEffect.external,
          reason: '',
          withdrawn: withdrawn.future,
        ),
      );
      await pumpEventQueue();
      final pending = container.read(assistantApprovalsProvider);
      expect(pending, hasLength(1));
      container
          .read(assistantApprovalsProvider.notifier)
          .answer(pending.single.id, false);
      expect(await approval, isFalse);
      withdrawn.complete();
      expect(reviewer.config, isNull);

      await container.read(assistantAlwaysAskProvider.notifier).set(false);
      expect(
        policy.gate.check(call, ToolEffect.external).decision,
        GateDecision.allow,
      );
      final port = policy.approvals! as AssistantApprovalPort;
      expect(port.userMessages, [for (var i = 2; i < 8; i++) '用户要求$i']);
      expect(config.messages.toString(), isNot(contains('用户要求7')));
      final review = await port.review(
        userMessages: port.userMessages,
        toolName: 'codemode',
        toolDescription: '运行脚本',
        arguments: const {'code': 'return 1'},
      );
      expect(review.verdict, ReviewVerdict.allow);
      expect(reviewer.config!.modelFullId, config.modelFullId);
      expect(reviewer.config!.providerApiBase, config.providerApiBase);
      expect(reviewer.config!.providerApiKey, config.providerApiKey);
      expect(reviewer.config!.tools, isNull);
      expect(reviewer.tools, isEmpty);
      expect(reviewer.config!.messages.last['content'], contains('用户要求7'));
    },
  );

  test(
    'reviewer has no invented user authorization when history is empty',
    () async {
      (container.read(chatHistoryStoreProvider) as _History).messages = [];
      final caps = await capabilities(_role('manager', [assistantPluginId]));
      final policy = await caps.toolPolicyFactory!(
        ApiConfig(
          settings: _settings,
          modelFullId: 'openai:gpt-test',
          providerApiBase: 'https://invalid.test',
          customConfig: const {},
          messages: const [
            {'role': 'user', 'content': '模型生成的派活任务'},
          ],
        ),
      );
      expect(
        (policy.approvals! as AssistantApprovalPort).userMessages,
        isEmpty,
      );
    },
  );

  for (final selected in <List<String>?>[
    null,
    ['memory', 'web_search'],
  ]) {
    test(
      'creating workspace preserves legacy assistant capability with plugins $selected',
      () async {
        final role = _role(
          'legacy',
          selected,
        ).copyWith(agentMode: RoleAgentMode.tool);
        await container.read(conversationsProvider.future);
        await container.read(conversationsProvider.notifier).addOne(role);
        final before = await capabilities(role);
        final space = await (await container.read(
          workspaceStoreProvider.future,
        )).create(name: '新空间');
        await before.workspaces!.onCreated!(space);
        final updated = await container
            .read(proactiveReplyGeneratorProvider)
            .loadConversation(role.id);
        expect(updated, isNotNull);
        expect(updated!.agentMode, isNull);
        expect(updated.hasAssistantCapability, isTrue);
        expect(updated.enabledPlugins, contains(assistantPluginId));
        expect(
          updated.enabledPlugins,
          contains(WorkspaceGrants.pluginIdOf(space.id)),
        );
        if (selected != null) {
          expect(updated.enabledPlugins, containsAll(selected));
        } else {
          final defaults = container
              .read(pluginManagerProvider)
              .getAllPlugins()
              .where(
                (plugin) =>
                    !isOfficePluginId(plugin.id) || plugin.id == 'web_search',
              )
              .map((plugin) => plugin.id);
          expect(updated.enabledPlugins, containsAll(defaults));
        }
        final after = await capabilities(updated);
        expect(after.toolPolicyFactory, isNotNull);
        expect(after.toolOwners['aicove_settings_set'], assistantPluginId);
        expect(
          after.workspaces!.shellEnvironment!(),
          containsPair('AICOVE_KEY_TEST', 'test-secret'),
        );
      },
    );
  }

  test('explicit policy overrides capabilities factory', () async {
    var factoryCalls = 0;
    const explicit = AgentToolPolicy(
      authorization: AgentToolAuthorization.manual,
    );
    final runner = TaskAgentRunner(
      loadSettings: () async => _settings,
      requestConfig: resolve,
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) async {
            expect(config.toolPolicy, same(explicit));
            return const ApiCallResult(
              replyText: '',
              processedText: '',
              pluginEvents: [],
              toolResults: [],
            );
          },
    );
    await runner.run(
      taskId: 'task',
      runId: 'run',
      transcript: '任务',
      capabilities: TaskAgentCapabilities(
        toolPolicyFactory: (_) async {
          factoryCalls++;
          return explicit;
        },
      ),
      preset: const TaskAgentPreset(),
      cancellation: KernelCancellation(),
      toolPolicy: explicit,
    );
    expect(factoryCalls, 0);
  });
}
