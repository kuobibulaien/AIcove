import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/database/database_provider.dart';
import '../../core/media/media_store.dart';
import '../../core/models/message_block.dart';
import '../../core/storage/app_data_directory.dart';
import '../agent_plugins/plugin_runtime.dart';
import '../auto_reply/data/proactive_owner_device.dart';
import '../auto_reply/data/proactive_reply_generator.dart';
import '../background_agent/background_agent_service.dart';
import '../chat/chat_providers.dart';
import '../context/providers/context_providers.dart';
import '../chat/conversation_providers.dart';
import '../chat/domain/message.dart';
import '../chat/services/chat_history_store.dart';
import '../chat/services/chat_send_service.dart';
import '../chat/services/chat_tts_handler.dart';
import '../chat/services/chat_types.dart';
import '../plugins/domain/handlers/ai_tool.dart';
import '../plugins/mcp/mcp_connector_plugin.dart';
import '../plugins/plugin_providers.dart';
import '../plugins/domain/plugin.dart';
import '../plugins/packages/package_plugin.dart';
import '../plugins/web_search/web_search_plugin.dart';
import '../settings/app_settings.dart';
import '../workspace/application/workspace_toolset.dart';
import '../workspace/application/workspace_shell.dart';
import '../workspace/domain/workspace_grants.dart';
import '../workspace/domain/workspace_models.dart';
import '../workspace/webapp/webapp_launcher.dart';
import '../workspace/workspace_providers.dart';
import 'application/delegate_task_plugin.dart';
import 'application/task_agent_runner.dart';
import 'application/task_agent_service.dart';
import 'application/task_agent_supervisor.dart';
import 'data/agent_task_store.dart';
import 'data/task_process_record.dart';
import 'data/task_sync_scanner.dart';
import 'domain/agent_task.dart';
import 'domain/task_relay.dart';

final agentTaskStoreProvider = Provider<AgentTaskStore>(
  (ref) => AgentTaskStore(ref.watch(databaseProvider)),
);

/// The errand agent service of this device (foreground isolate only).
final taskAgentServiceProvider = FutureProvider<TaskAgentService>((ref) async {
  final store = ref.watch(agentTaskStoreProvider);
  final directory = Directory(
    p.join((await appDataDirectory()).path, 'task_agent'),
  );
  final apiRunner = ref.watch(backgroundApiRunnerProvider);
  final history = ref.read(chatHistoryStoreProvider);
  return TaskAgentService(
    store: store,
    process: TaskProcessRecord(directory),
    runner: TaskAgentRunner(
      // Task steps are compacted as task progress, never as companion chat.
      summarizerFactory: () =>
          ref.read(runtimeContextSummarizerProvider.future),
      loadSettings: () => ref.read(appSettingsProvider.future),
      executor:
          ({
            required config,
            required tools,
            required sessionId,
            required cancellation,
          }) => apiRunner.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: null,
            responseProcessors: const [],
            availableTools: tools,
            cancellation: cancellation,
          ),
    ),
    capabilities: (task, runId, cancellation) =>
        _resolveCapabilities(ref, task, runId, cancellation),
    writeReceipt: (recorded) => history.appendUserMessage(
      conversationId: recorded.task.conversationId,
      message: Message(
        id: recorded.messageId,
        role: 'user',
        content: recorded.block.content,
        blocks: [recorded.block],
        createdAt: DateTime.now(),
        status: 'sent',
      ),
      displayText: recorded.block.content,
    ),
    findReceipt: (receiptId) => _findReceipt(ref, receiptId),
    relay: (conversationId, receipt) => _relay(ref, conversationId, receipt),
    ownsConversation: (conversationId) async =>
        (await ProactiveOwnership.load()).owns(conversationId),
    deviceId: () => MediaStore.localDeviceId,
  );
});

final delegateTaskPortProvider = Provider<DelegateTaskPort>(
  (ref) => _DelegatePort(ref),
);

/// The single rule (ADR0087 §1): role grant ∩ preset ∩ enabled ∩ present on
/// this device. Office plugins follow the role's plugin selection, as they
/// did on the chat model.
Future<TaskAgentCapabilities> _resolveCapabilities(
  Ref ref,
  AgentTask task,
  String runId,
  KernelCancellation cancellation,
) async {
  final conversation = await ref
      .read(proactiveReplyGeneratorProvider)
      .loadConversation(task.conversationId);
  if (conversation == null) return const TaskAgentCapabilities();
  await ensurePluginConfigsLoaded(ref);
  final enabled = conversation.enabledPlugins?.toSet();
  final plugins = ref.read(pluginManagerProvider).getAllPlugins();
  final extension = await resolveTaskPluginCapabilities(
    plugins,
    enabled,
    executable: true,
  );
  final store = await ref.read(workspaceStoreProvider.future);
  final workspaceIds = WorkspaceGrants.effective(
    roleGrants: WorkspaceGrants.forRole(
      conversation.id,
      conversation.enabledPlugins,
    ),
    presetAllows: null,
    // The workspace plugin has no global switch yet; grants decide.
    pluginEnabled: true,
    localIds: [for (final workspace in await store.list()) workspace.id],
  );
  return TaskAgentCapabilities(
    tools: extension.tools,
    prompts: extension.prompts,
    toolOwners: extension.toolOwners,
    workspaces: WorkspaceToolset(
      store: store,
      enableScripts: true,
      enableShell: WorkspaceShell.available(platform: Platform.operatingSystem),
      workspaceIds: workspaceIds,
      runId: runId,
      isCancelled: () => cancellation.isCancelled,
      onCreated: (workspace) =>
          _grantWorkspace(ref, task.conversationId, workspace),
      runWebApp: (ws, path) async => (await ref.read(
        webAppLauncherProvider.future,
      )).openForAgent(ws, path),
    ),
  );
}

/// Resolves role-selected, enabled, locally installed package/office plugins.
/// The runner applies the preset's narrowing to both tools and prompt fragments.
Future<TaskAgentCapabilities> resolveTaskPluginCapabilities(
  Iterable<Plugin> plugins,
  Set<String>? enabled, {
  bool executable = true,
}) async {
  final runtime = PluginRuntime.fromPlugins(plugins);
  final selected = runtime.selectForRole(enabled).toSet();
  final tools = <AITool>[];
  final prompts = <String, String>{};
  final owners = <String, String>{};
  for (final plugin in plugins) {
    if (!selected.contains(plugin.id)) continue;
    final contributed = switch (plugin) {
      WebSearchPlugin() => plugin.getTools(),
      McpConnectorPlugin() => plugin.getTools(),
      PackagePlugin() => await (() async {
        final prompt = await plugin.prompt();
        if (prompt != null) prompts[plugin.id] = prompt;
        return plugin.getTools(executable: executable);
      })(),
      _ => const <AITool>[],
    };
    for (final tool in contributed) {
      tools.add(tool);
      owners[tool.name] = plugin.id;
    }
  }
  return TaskAgentCapabilities(
    tools: tools,
    prompts: prompts,
    toolOwners: owners,
  );
}

/// A workspace the errand agent created belongs to its role. "All plugins"
/// is first written out, since it grants no workspace.
Future<void> _grantWorkspace(
  Ref ref,
  String conversationId,
  WorkspaceInfo workspace,
) async {
  final conversation = await ref
      .read(proactiveReplyGeneratorProvider)
      .loadConversation(conversationId);
  if (conversation == null) return;
  final current =
      conversation.enabledPlugins ??
      [
        for (final plugin in ref.read(pluginManagerProvider).getAllPlugins())
          if (!isOfficePluginId(plugin.id) || plugin.id == 'web_search')
            plugin.id,
      ];
  final grant = WorkspaceGrants.pluginIdOf(workspace.id);
  if (current.contains(grant)) return;
  await ref
      .read(conversationsProvider.notifier)
      .applyContactEdit(conversationId, enabledPlugins: [...current, grant]);
}

Future<TaskReceiptBlock?> _findReceipt(Ref ref, String receiptId) async {
  final message = await ref
      .read(chatHistoryStoreProvider)
      .loadMessageById(
        taskReceiptMessageId(receiptId),
        preferProjection: false,
      );
  for (final block in message?.blocks ?? const <MessageBlock>[]) {
    if (block is TaskReceiptBlock && block.receiptId == receiptId) return block;
  }
  return null;
}

/// Relays a receipt in persona through the proactive reply chain. Returns
/// false to retry later: while the chat is generating, or on failure.
Future<bool> _relay(
  Ref ref,
  String conversationId,
  TaskReceiptBlock receipt,
) async {
  if (ref.read(conversationSendingProvider(conversationId))) return false;
  if (await _alreadyRelayed(ref, conversationId, receipt.receiptId)) {
    return true;
  }
  final generator = ref.read(proactiveReplyGeneratorProvider);
  final conversation = await generator.loadConversation(conversationId);
  if (conversation == null) return true;
  final text = await generator.generate(
    conversation: conversation,
    reminder: _relayReminder(receipt),
    turnId: 'task_relay_${receipt.receiptId}',
  );
  if (text.trim().isEmpty) return false;
  // The user may have started typing meanwhile; their turn goes first.
  if (ref.read(conversationSendingProvider(conversationId))) return false;
  if (await _alreadyRelayed(ref, conversationId, receipt.receiptId)) {
    return true;
  }
  final chatSend = ref.read(chatSendServiceProvider);
  final settings = await ref.read(appSettingsProvider.future);
  final apiResult = await chatSend.processAssistantReplyWithPlugins(
    conv: conversation,
    rawReplyText: text,
  );
  final built = chatSend.buildAssistantMessages(
    apiResult: apiResult,
    settings: settings,
  );
  final raw = built.rawMessage;
  await ref
      .read(chatTtsHandlerProvider)
      .deliverSegmentedMessages(
        convId: conversationId,
        userMsgId: '',
        buildResult: AssistantMessageBuildResult(
          rawMessage: raw?.copyWith(
            rawPayload: {
              ...?raw.rawPayload,
              taskRelayReceiptKey: receipt.receiptId,
            },
          ),
          messages: built.messages,
          lastMessageText: built.lastMessageText,
        ),
        replyText: apiResult.rawReplyText,
        pluginEvents: apiResult.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
  return true;
}

/// A relay from any device, synced here, counts.
Future<bool> _alreadyRelayed(
  Ref ref,
  String conversationId,
  String receiptId,
) async {
  final rows = await ref
      .read(databaseProvider)
      .customSelect(
        'SELECT 1 FROM messages WHERE conversation_id=? AND deleted_at IS NULL '
        'AND raw_payload LIKE ? LIMIT 1',
        variables: [
          Variable(conversationId),
          Variable('%"$taskRelayReceiptKey":"$receiptId"%'),
        ],
      )
      .get();
  return rows.isNotEmpty;
}

String _relayReminder(TaskReceiptBlock receipt) =>
    switch (receipt.receiptStatus) {
      TaskReceiptStatus.needsInput =>
        '后台助手办事时有个问题要问用户（见上一条杂活回执）。用你的口吻自然地问用户，'
            '不要提「回执」「后台助手」这些词。',
      TaskReceiptStatus.done =>
        '你之前交给后台去办的事有结果了（见上一条杂活回执）。用你的口吻把结果告诉用户，'
            '只说回执里有的内容，不要编造，不要提「回执」这个词。',
      _ =>
        '你之前交给后台去办的事没办成（见上一条杂活回执）。用你的口吻如实告诉用户，'
            '不要编造结果，不要提「回执」这个词。',
    };

class _DelegatePort implements DelegateTaskPort, TaskSteeringPort {
  @override
  Future<Map<String, Object?>> steer({
    required String conversationId,
    required String taskId,
    required String instruction,
  }) async {
    final service = await _service;
    final task = await service.store.get(taskId);
    if (task == null || task.conversationId != conversationId)
      return {'error': '没有这个任务'};
    final outcome = await service.steer(
      taskId: taskId,
      instruction: instruction,
    );
    return outcome == TaskControlOutcome.applied
        ? {'task_id': taskId, 'status': 'steering_accepted'}
        : {'error': '这个任务已经结束'};
  }

  _DelegatePort(this._ref);

  final Ref _ref;

  Future<TaskAgentService> get _service =>
      _ref.read(taskAgentServiceProvider.future);

  Future<String?> _requestKey(String? callKey) async =>
      callKey == null ? null : '${await MediaStore.localDeviceId}|$callKey';

  static String _controlId(String? requestKey) => requestKey == null
      ? 'ctl_${DateTime.now().microsecondsSinceEpoch}'
      : 'ctl_${requestKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';

  @override
  Future<Map<String, Object?>> start({
    required String conversationId,
    required String instruction,
    required String? callKey,
  }) async {
    final service = await _service;
    if (!await service.enabled) {
      return {'error': '后台办事已被用户关闭，这件事现在办不了'};
    }
    try {
      final task = await service.start(
        conversationId: conversationId,
        instruction: instruction,
        requestKey: await _requestKey(callKey),
      );
      return {'task_id': task.id, 'status': 'accepted'};
    } on AgentTaskKeyConflict {
      return {'error': '请求重复'};
    }
  }

  @override
  Future<Map<String, Object?>> reply({
    required String conversationId,
    required String taskId,
    required String answer,
    required String? callKey,
  }) async {
    final service = await _service;
    final controlId = _controlId(await _requestKey(callKey));
    final task = await service.store.get(taskId);
    if (task != null && task.conversationId != conversationId) {
      return {'error': '没有这个任务'};
    }
    if (task != null) {
      final outcome = await service.reply(
        taskId: taskId,
        controlId: controlId,
        answersReceiptId: task.questionReceiptId,
        answer: answer,
      );
      return outcome == TaskControlOutcome.applied
          ? {'task_id': taskId, 'status': 'resumed'}
          : {'error': '这个任务现在不在等回答'};
    }
    final question = await _openQuestion(conversationId, taskId);
    if (question == null) return {'error': '没有这个任务，或它没有在等回答'};
    await _writeControl(
      conversationId,
      TaskControlBlock(
        messageId: 'task_control_$controlId',
        controlId: controlId,
        taskId: taskId,
        kind: TaskControlKind.reply,
        answersReceiptId: question,
        text: answer,
      ),
    );
    return {'task_id': taskId, 'status': 'sent_to_executor'};
  }

  @override
  Future<Map<String, Object?>> cancel({
    required String conversationId,
    required String taskId,
    required String? callKey,
  }) async {
    final service = await _service;
    final controlId = _controlId(await _requestKey(callKey));
    final task = await service.store.get(taskId);
    if (task != null && task.conversationId != conversationId) {
      return {'error': '没有这个任务'};
    }
    if (task != null) {
      final outcome = await service.cancel(
        taskId: taskId,
        controlId: controlId,
      );
      return outcome == TaskControlOutcome.applied
          ? {'task_id': taskId, 'status': 'cancelled'}
          : {'error': '这个任务已经结束'};
    }
    if (await _latestReceipt(conversationId, taskId) == null) {
      return {'error': '没有这个任务'};
    }
    await _writeControl(
      conversationId,
      TaskControlBlock(
        messageId: 'task_control_$controlId',
        controlId: controlId,
        taskId: taskId,
        kind: TaskControlKind.cancel,
      ),
    );
    return {'task_id': taskId, 'status': 'sent_to_executor'};
  }

  /// A task run by another device: the control travels with the chat sync
  /// and is applied there (ADR0088 §6).
  Future<void> _writeControl(String conversationId, TaskControlBlock block) =>
      _ref
          .read(chatHistoryStoreProvider)
          .appendUserMessage(
            conversationId: conversationId,
            message: Message(
              id: block.messageId,
              role: 'user',
              content: '',
              blocks: [block],
              createdAt: DateTime.now(),
              status: 'sent',
            ),
            displayText: '',
            updatePreview: false,
          );

  Future<TaskReceiptBlock?> _latestReceipt(
    String conversationId,
    String taskId,
  ) async {
    final rows = await _ref
        .read(databaseProvider)
        .customSelect(
          'SELECT id FROM messages WHERE conversation_id=? '
          'AND deleted_at IS NULL AND id LIKE ? ESCAPE ? '
          'ORDER BY created_at DESC LIMIT 1',
          variables: [
            Variable(conversationId),
            Variable('${_escapeLike(taskReceiptMessageId('${taskId}_'))}%'),
            const Variable(r'\'),
          ],
        )
        .get();
    if (rows.isEmpty) return null;
    final id = rows.single.read<String>('id');
    return _findReceipt(_ref, id.substring(taskReceiptMessageId('').length));
  }

  Future<String?> _openQuestion(String conversationId, String taskId) async {
    final receipt = await _latestReceipt(conversationId, taskId);
    return receipt?.receiptStatus == TaskReceiptStatus.needsInput
        ? receipt!.receiptId
        : null;
  }

  static String _escapeLike(String text) =>
      text.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
}

/// Started once by the app shell (foreground isolate).
final taskAgentSupervisorProvider = Provider<TaskAgentSupervisor>((ref) {
  final supervisor = TaskAgentSupervisor(
    service: ref.read(taskAgentServiceProvider.future),
    scanner: TaskSyncScanner(ref.watch(databaseProvider)),
    loadBlocks: (messageId) async =>
        (await ref
                .read(chatHistoryStoreProvider)
                .loadMessageById(messageId, preferProjection: false))
            ?.blocks ??
        const <MessageBlock>[],
  );
  ref.onDispose(supervisor.stop);
  return supervisor;
});

/// Tasks of this device, newest first (task list page).
final agentTaskListProvider = FutureProvider.autoDispose<List<AgentTask>>(
  (ref) => ref.watch(agentTaskStoreProvider).recent(),
);

/// One task by id, for the running bar under a `delegate_task` call.
final agentTaskByIdProvider = FutureProvider.autoDispose
    .family<AgentTask?, String>(
      (ref, taskId) => ref.watch(agentTaskStoreProvider).get(taskId),
    );

/// The kill switch as stored (ADR0088 §8).
final taskAgentEnabledProvider = FutureProvider.autoDispose<bool>(
  (ref) async => (await ref.watch(agentTaskStoreProvider).readSwitch()).$1,
);
