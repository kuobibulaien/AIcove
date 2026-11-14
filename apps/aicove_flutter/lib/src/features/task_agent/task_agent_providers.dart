import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation, ToolEffect;
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/database_provider.dart';
import '../../core/media/media_store.dart';
import '../../core/models/message_block.dart';
import '../../core/storage/app_data_directory.dart';
import '../../core/services/system_reminder_service.dart';
import '../agent_plugins/plugin_runtime.dart';
import '../agent_plugins/tool_policy.dart';
import '../agent_plugins/plugin_request_context.dart';
import '../agent_plugins/plugin_request_scope.dart';
import '../assistant/assistant_providers.dart';
import '../assistant/application/assistant_approvals.dart';
import '../assistant/application/assistant_plugin.dart';
import '../assistant/application/assistant_review.dart';
import '../assistant/application/assistant_settings_tools.dart';
import '../assistant/application/assistant_tool_group.dart';
import '../auto_reply/data/proactive_owner_device.dart';
import '../agent_context/domain/agent_runtime_contracts.dart';
import '../auto_reply/data/proactive_reply_generator.dart';
import '../background_agent/background_agent_service.dart';
import '../chat/chat_providers.dart';
import '../context/providers/context_providers.dart';
import '../chat/conversation_providers.dart';
import '../chat/domain/message.dart';
import '../chat/domain/conversation.dart';
import '../chat/services/chat_history_store.dart';
import '../chat/services/chat_send_service.dart';
import '../chat/services/chat_tts_handler.dart';
import '../chat/services/chat_types.dart';
import '../chat/services/provider_key_failure.dart';
import '../plugins/domain/handlers/ai_tool.dart';
import '../plugins/image/image_config.dart';
import '../plugins/prompts/plugin_prompts.dart';
import '../plugins/tts/voice_request.dart';
import '../plugins/plugin_providers.dart';
import '../plugins/domain/plugin.dart';
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
    inlineWait: const Duration(seconds: 3),
    isReceiptRelayed: (conversationId, receiptId) =>
        _alreadyRelayed(ref, conversationId, receiptId),
    process: TaskProcessRecord(directory),
    runner: TaskAgentRunner(
      resolveConversationId: (id) async =>
          (await store.get(id))?.conversationId,
      keyFailureRecorder: ref.read(providerKeyFailureRecorderProvider),
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
    capabilities: (task, runId, cancellation, {bool readOnly = false}) =>
        _resolveCapabilities(
          ref,
          task,
          runId,
          cancellation,
          readOnly: readOnly,
        ),
    writeReceipt: (recorded) =>
        ref.read(databaseProvider).transaction(() async {
          final conversation = await ref
              .read(proactiveReplyGeneratorProvider)
              .loadConversation(recorded.task.conversationId);
          if (conversation == null) return;
          await history.appendUserMessage(
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
          );
        }),
    findReceipt: (receiptId) => _findReceipt(ref, receiptId),
    relay: (conversationId, receipt) => _relay(ref, conversationId, receipt),
    ownsConversation: (conversationId) async =>
        (await ProactiveOwnership.load()).owns(conversationId),
    conversationBusy: (conversationId) =>
        ref.read(conversationSendingProvider(conversationId)),
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
  KernelCancellation cancellation, {
  bool readOnly = false,
}) async {
  final conversation = await ref
      .read(proactiveReplyGeneratorProvider)
      .loadConversation(task.conversationId);
  if (conversation == null) return const TaskAgentCapabilities();
  return resolveConversationTaskCapabilities(
    ref,
    conversation,
    instruction: task.instruction,
    runId: runId,
    cancellation: cancellation,
    readOnly: readOnly,
  );
}

/// Resolves one role's backend without loading task storage or chat history.
Future<TaskAgentCapabilities> resolveConversationTaskCapabilities(
  Ref ref,
  Conversation conversation, {
  required String instruction,
  required String runId,
  required KernelCancellation cancellation,
  bool readOnly = false,
}) async {
  await ensurePluginConfigsLoaded(ref);
  final enabled = conversation.enabledPlugins?.toSet();
  final plugins = ref.read(pluginManagerProvider).getAllPlugins();
  final inputs = PluginRequestInputs(
    ref: ref,
    settings: await ref.read(appSettingsProvider.future),
    conversationId: conversation.id,
    rolePluginIds: enabled,
    imageConfig: const ImageConfig(),
    voiceRequest: VoiceRequest(ownerId: conversation.id),
    pluginPrompts: const PluginPrompts(),
    history: const [],
    previousUserMessageTime: null,
    useFastImageRoute: false,
    useStableImageRoute: false,
    supportsToolCalling: true,
    reminders: const SystemReminderService(),
  );
  final extension = await resolveTaskPluginCapabilities(
    plugins,
    enabled,
    inputs: inputs,
  );
  if (conversation.hasAssistantCapability) {
    final runtime = PluginRuntime();
    try {
      runtime.install(
        assistantAgentPlugin(
          ref.read(assistantToolsetProvider),
          conversationId: conversation.id,
          writes: readOnly ? null : ref.read(assistantWriteToolsProvider),
          settings: readOnly ? null : ref.read(assistantSettingsToolsProvider),
          cards: ref.read(assistantCardToolsProvider),
          checkup: ref.read(assistantCheckupProvider),
          groups: ref.read(assistantToolGroupsProvider),
        ),
      );
      await _collectTaskPluginCapabilities(
        runtime,
        [assistantPluginId],
        inputs,
        tools: extension.tools,
        prompts: extension.prompts,
        owners: extension.toolOwners,
      );
    } finally {
      await runtime.scope.dispose();
    }
  }
  final store = await ref.read(workspaceStoreProvider.future);
  final localIds = [for (final workspace in await store.list()) workspace.id];
  final workspaceIds = WorkspaceGrants.effective(
    roleGrants: conversation.hasAssistantCapability
        ? localIds.toSet()
        : WorkspaceGrants.forRole(conversation.id, conversation.enabledPlugins),
    presetAllows: null,
    // The workspace plugin has no global switch yet; grants decide.
    pluginEnabled: true,
    localIds: localIds,
  );
  final prefs = await SharedPreferences.getInstance();
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final selectionKey = 'workspace_current_${conversation.id}';
  return TaskAgentCapabilities(
    tools: [
      for (final tool in extension.tools)
        if (!readOnly || tool.effect != ToolEffect.write) tool,
    ],
    prompts: extension.prompts,
    toolOwners: extension.toolOwners,
    toolPolicyFactory: conversation.hasAssistantCapability
        ? (config) => _assistantTaskToolPolicy(ref, config, conversation.id)
        : null,
    workspaces: WorkspaceToolset(
      store: store,
      userSkillRoots: [
        if (home != null && home.isNotEmpty) ...[
          p.join(home, '.agents', 'skills'),
          p.join(home, '.claude', 'skills'),
        ],
      ],
      currentWorkspaceId: prefs.getString(selectionKey),
      currentLocalDirectory: prefs.getString('${selectionKey}_local'),
      onWorkspaceChanged: (id) async {
        await prefs.setString(selectionKey, id);
      },
      onLocalDirectoryChanged: (path) async {
        if (path == null) {
          await prefs.remove('${selectionKey}_local');
        } else {
          await prefs.setString('${selectionKey}_local', path);
        }
      },
      enableLocalFiles: true,
      enableScripts: true,
      enableShell:
          !readOnly &&
          WorkspaceShell.available(platform: Platform.operatingSystem),
      workspaceIds: workspaceIds,
      runId: runId,
      isCancelled: () => cancellation.isCancelled,
      onCreated: (workspace) =>
          _grantWorkspace(ref, conversation.id, workspace),
      shellEnvironment: () {
        final settings = ref.read(appSettingsProvider).valueOrNull;
        return !conversation.hasAssistantCapability || settings == null
            ? const <String, String>{}
            : channelKeyEnvironment(settings);
      },
      runLocalWebApp: (root, page) async => (await ref.read(
        webAppLauncherProvider.future,
      )).openLocalDirectoryForAgent(root, page),
      runWebApp: (ws, path) async => (await ref.read(
        webAppLauncherProvider.future,
      )).openForAgent(ws, path),
    ),
  );
}

/// Plugins delegated to the backend; media and persona remain in chat.
bool isTaskBackendPluginId(String id) =>
    isOfficePluginId(id) || id.startsWith('pkg:');

List<String> _selectedTaskPluginIds(
  PluginRuntime runtime,
  Set<String>? enabled,
) => [
  for (final id in runtime.selectForRole(enabled))
    if (isTaskBackendPluginId(id)) id,
];

/// Checks role selection and usability without building prompts or tools.
Future<Set<String>> resolveActiveTaskPluginIds(
  Iterable<Plugin> plugins,
  Set<String>? enabled, {
  required PluginRequestInputs inputs,
}) async {
  final runtime = PluginRuntime();
  try {
    for (final plugin in plugins) {
      runtime.install(plugin.agentPlugin, enabled: plugin.enabled);
    }
    final ids = <String>{};
    for (final scope in runtime.requestScopes(
      runtime.snapshot(),
      _selectedTaskPluginIds(runtime, enabled),
      inputs,
    )) {
      try {
        if (scope.active) ids.add(scope.pluginId);
      } finally {
        await scope.dispose();
      }
    }
    return ids;
  } finally {
    await runtime.scope.dispose();
  }
}

/// Resolves active backend plugins. Presets may narrow tools and prompts later.
Future<TaskAgentCapabilities> resolveTaskPluginCapabilities(
  Iterable<Plugin> plugins,
  Set<String>? enabled, {
  required PluginRequestInputs inputs,
}) async {
  final runtime = PluginRuntime();
  try {
    for (final plugin in plugins) {
      runtime.install(plugin.agentPlugin, enabled: plugin.enabled);
    }
    final tools = <AITool>[];
    final prompts = <String, String>{};
    final owners = <String, String>{};
    await _collectTaskPluginCapabilities(
      runtime,
      _selectedTaskPluginIds(runtime, enabled),
      inputs,
      tools: tools,
      prompts: prompts,
      owners: owners,
    );
    return TaskAgentCapabilities(
      tools: tools,
      prompts: prompts,
      toolOwners: owners,
    );
  } finally {
    await runtime.scope.dispose();
  }
}

Future<void> _collectTaskPluginCapabilities(
  PluginRuntime runtime,
  List<String> selected,
  PluginRequestInputs inputs, {
  required List<AITool> tools,
  required Map<String, String> prompts,
  required Map<String, String> owners,
}) async {
  final context = PluginRequestContext(
    userMessage: '',
    supportsToolCalling: inputs.supportsToolCalling,
    conversationId: inputs.conversationId,
    rawHistory: inputs.history,
  );
  for (final scope in runtime.requestScopes(
    runtime.snapshot(),
    selected,
    inputs,
  )) {
    try {
      if (!scope.active) continue;
      // Package prompts prepare script declarations used by tools().
      final prompt = await scope.prompt(context);
      if (prompt != null) prompts[scope.pluginId] = prompt;
      for (final tool in scope.tools()) {
        tools.add(tool);
        owners[tool.name] = scope.pluginId;
      }
    } finally {
      await scope.dispose();
    }
  }
}

/// The assistant's original gate, now applied to the backend execution model.
Future<AgentToolPolicy> _assistantTaskToolPolicy(
  Ref ref,
  ApiConfig config,
  String conversationId,
) async {
  final alwaysAsk = await ref.read(assistantAlwaysAskProvider.future);
  bool alwaysAskNow() =>
      ref.read(assistantAlwaysAskProvider).valueOrNull ?? alwaysAsk;
  final store = await ref.read(workspaceStoreProvider.future);
  final spaceNames = {
    for (final space in await store.list()) space.id: space.name,
  };
  final toolset = ref.read(assistantToolsetProvider);
  final writes = ref.read(assistantWriteToolsProvider);
  final settingsTools = ref.read(assistantSettingsToolsProvider);
  final groups = ref.read(assistantToolGroupsProvider);
  final riskOf = AssistantRequestScope.riskOf(
    toolset,
    writes,
    settings: settingsTools,
    groups: groups,
  );
  final descriptions = {
    for (final tool in [
      ...toolset.tools(),
      ...writes.tools(),
      ...settingsTools.tools(),
      for (final group in groups) ...group.tools(),
    ])
      tool.name: tool.description,
  };
  // Approval uses the user's words, never a model-authored task brief.
  final history = await ref
      .read(chatHistoryStoreProvider)
      .loadCanonicalContextMessages(conversationId, limit: 30);
  final userMessages = [
    for (final message in history)
      if (message.role == 'user' &&
          message.content.trim().isNotEmpty &&
          (message.blocks?.any((block) => block is TaskReceiptBlock) != true))
        message.content.trim(),
  ];
  final reviewer = AssistantReviewer(
    (messages) async =>
        (await ref
                .read(backgroundApiRunnerProvider)
                .executeApiCall(
                  config: ApiConfig(
                    settings: config.settings,
                    modelFullId: config.modelFullId,
                    providerApiBase: config.providerApiBase,
                    providerApiKey: config.providerApiKey,
                    providerId: config.providerId,
                    providerApiKeyItemId: config.providerApiKeyItemId,
                    providerApiKeyItemIndex: config.providerApiKeyItemIndex,
                    providerApiKeyStrategy: config.providerApiKeyStrategy,
                    customConfig: config.customConfig,
                    messages: messages,
                    providerRequestOptions: config.providerRequestOptions,
                    cancellation: config.cancellation,
                  ),
                  sessionId: '${config.toolResultOwner}_review',
                  userText: null,
                  responseProcessors: const [],
                  availableTools: const [],
                  cancellation: config.cancellation,
                ))
            .replyText,
  );
  return AgentToolPolicy(
    authorization: AgentToolAuthorization.allowAll,
    customGate: AssistantToolGate(riskOf, alwaysAsk: alwaysAskNow),
    redactor: redactorForCredentials(settings: config.settings),
    approvalTimeout: const Duration(minutes: 5),
    approvals: AssistantApprovalPort(
      riskOf: riskOf,
      describe: (name, args) => name == 'bash'
          ? ApprovalPrompt.workspaceShell(
              spaceNames[config.currentWorkspaceId?.call()] ??
                  config.currentWorkspaceId?.call() ??
                  '未选择',
              '${args['command']}',
            )
          : name == 'codemode'
          ? ApprovalPrompt.workspaceScript(
              spaceNames[config.currentWorkspaceId?.call()] ??
                  config.currentWorkspaceId?.call() ??
                  '未选择',
            )
          : groups.ownerOf(name)?.describe(name, args) ??
                (AssistantSettingsTools.describes(name)
                    ? settingsTools.describe(name, args)
                    : writes.describe(name, args)),
      toolDescription: (name) => descriptions[name] ?? name,
      userMessages: userMessages.length <= 6
          ? userMessages
          : userMessages.sublist(userMessages.length - 6),
      review: reviewer.review,
      askUser: ref.read(assistantApprovalsProvider.notifier).ask,
      alwaysAsk: alwaysAskNow,
    ),
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
      .applyContactEdit(
        conversationId,
        enabledPlugins: [
          ...current,
          // Explicit selection clears the legacy mode; migrate its capability.
          if (conversation.hasAssistantCapability &&
              !current.contains(assistantPluginId))
            assistantPluginId,
          grant,
        ],
      );
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
  final history = ref.read(chatHistoryStoreProvider);
  Future<bool> receiptActive() => history.isRawMessageActive(
    conversationId: conversationId,
    messageId: taskReceiptMessageId(receipt.receiptId),
  );
  if (!await receiptActive()) return true;
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
  if (!await receiptActive()) return true;
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
        shouldCommit: receiptActive,
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
        'SELECT role, status, raw_payload FROM messages WHERE conversation_id=? AND deleted_at IS NULL '
        "AND (raw_payload LIKE ? OR (role='assistant' AND raw_payload LIKE ?))",
        variables: [
          Variable(conversationId),
          Variable('%"$taskRelayReceiptKey":"$receiptId"%'),
          Variable('%$receiptId%'),
        ],
      )
      .get();
  bool hasReceipt(Object? value) {
    if (value is Map) {
      if (value['receipt_id'] == receiptId) {
        return true;
      }
      return value.values.any(hasReceipt);
    }
    if (value is List) return value.any(hasReceipt);
    if (value is String) {
      try {
        return hasReceipt(jsonDecode(value));
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  for (final row in rows) {
    try {
      final payload = jsonDecode(row.read<String>('raw_payload'));
      if (payload is! Map<String, dynamic>) continue;
      // Dedicated relay markers are committed persona replies, including sync.
      if (taskRelayReceiptIdOf(payload) == receiptId) return true;
      // Tool progress also persists inline receipts, even if the reply later
      // fails or is cancelled. Only a completed foreground reply relays them.
      final runStatus = payload['runStatus'];
      if (row.read<String>('role') == 'assistant' &&
          row.read<String>('status') != 'sending' &&
          (runStatus == null || runStatus == 'completed') &&
          payload['stopReason'] != 'inProgress' &&
          hasReceipt(payload)) {
        return true;
      }
    } on FormatException {
      continue;
    }
  }
  return false;
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

class _DelegatePort implements DelegateTaskPort {
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
    bool readOnly = false,
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
        readOnly: readOnly,
      );
      final inline = service.inlineWait > Duration.zero
          ? await service.waitForReceipt(
              task.id,
              isCancelled: () =>
                  ToolCallContext.current?.isCancelled?.call() ?? false,
            )
          : null;
      if (inline != null) {
        return {
          'task_id': task.id,
          'receipt_id': inline.receiptId,
          'status': TaskReceiptBlock.statusName(inline.receiptStatus),
          'summary': inline.summary,
          if (inline.question != null) 'question': inline.question,
          if (inline.detail != null) 'detail': inline.detail,
          if (inline.artifacts.isNotEmpty)
            'artifacts': [for (final a in inline.artifacts) a.toJson()],
        };
      }
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
      if (task.status.isTerminal) return {'error': '这个任务已经结束'};
      final waiting = task.status == AgentTaskStatus.needsInput;
      final outcome = waiting
          ? await service.reply(
              taskId: taskId,
              controlId: controlId,
              answersReceiptId: task.questionReceiptId,
              answer: answer,
            )
          : await service.steer(taskId: taskId, instruction: answer);
      return outcome == TaskControlOutcome.applied
          ? {
              'task_id': taskId,
              'status': waiting ? 'resumed' : 'steering_accepted',
            }
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
  final subscription = ref
      .read(conversationIdleEventsProvider)
      .stream
      .listen(
        (conversationId) =>
            unawaited(supervisor.flushConversation(conversationId)),
      );
  ref.onDispose(() {
    unawaited(subscription.cancel());
    supervisor.stop();
  });
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
