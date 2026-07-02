library;

import '../../chat/domain/message.dart';

/// Agent 的运行类型。
///
/// 这不是 UI 分类，而是运行时调度视角下的职责边界。
enum AgentKind {
  chat,
  background,
  analyzer,
  renderer,
  summarizer,
  toolAgent,
}

extension AgentKindX on AgentKind {
  String get id {
    switch (this) {
      case AgentKind.chat:
        return 'chat';
      case AgentKind.background:
        return 'background';
      case AgentKind.analyzer:
        return 'analyzer';
      case AgentKind.renderer:
        return 'renderer';
      case AgentKind.summarizer:
        return 'summarizer';
      case AgentKind.toolAgent:
        return 'tool_agent';
    }
  }
}

/// Agent 的触发来源。
///
/// 触发方式不应该决定上下文组装规则；聊天、后台扫描、主动关怀
/// 都应复用同一套 Agent Context Runtime 契约。
enum AgentTriggerKind {
  userMessage,
  scheduled,
  stateChange,
  backgroundScan,
  toolResult,
}

extension AgentTriggerKindX on AgentTriggerKind {
  String get id {
    switch (this) {
      case AgentTriggerKind.userMessage:
        return 'user_message';
      case AgentTriggerKind.scheduled:
        return 'scheduled';
      case AgentTriggerKind.stateChange:
        return 'state_change';
      case AgentTriggerKind.backgroundScan:
        return 'background_scan';
      case AgentTriggerKind.toolResult:
        return 'tool_result';
    }
  }
}

/// Agent 运行结果的投递通道。
///
/// 输出内容是否进入前台聊天、候选缓存、后台 trace 或记忆库，
/// 应由 delivery channel 决定，而不是散落在不同业务流程里。
enum AgentDeliveryChannelKind {
  foregroundConversation,
  backgroundTraceOnly,
  triggerCandidateStore,
  memoryStore,
  notification,
  outputEventQueue,
}

extension AgentDeliveryChannelKindX on AgentDeliveryChannelKind {
  String get id {
    switch (this) {
      case AgentDeliveryChannelKind.foregroundConversation:
        return 'foreground_conversation';
      case AgentDeliveryChannelKind.backgroundTraceOnly:
        return 'background_trace_only';
      case AgentDeliveryChannelKind.triggerCandidateStore:
        return 'trigger_candidate_store';
      case AgentDeliveryChannelKind.memoryStore:
        return 'memory_store';
      case AgentDeliveryChannelKind.notification:
        return 'notification';
      case AgentDeliveryChannelKind.outputEventQueue:
        return 'output_event_queue';
    }
  }
}

/// trace 所属运行面。
enum AgentTraceKind {
  foreground,
  background,
}

extension AgentTraceKindX on AgentTraceKind {
  String get id {
    switch (this) {
      case AgentTraceKind.foreground:
        return 'foreground';
      case AgentTraceKind.background:
        return 'background';
    }
  }
}

/// Agent 上下文分层。
enum AgentContextLayer {
  identity,
  memory,
  conversationWindow,
  runtimeFacts,
  capabilityBoundary,
  outputContract,
}

extension AgentContextLayerX on AgentContextLayer {
  String get id {
    switch (this) {
      case AgentContextLayer.identity:
        return 'identity';
      case AgentContextLayer.memory:
        return 'memory';
      case AgentContextLayer.conversationWindow:
        return 'conversation_window';
      case AgentContextLayer.runtimeFacts:
        return 'runtime_facts';
      case AgentContextLayer.capabilityBoundary:
        return 'capability_boundary';
      case AgentContextLayer.outputContract:
        return 'output_contract';
    }
  }
}

/// Agent 在上下文运行时中允许装配的资产类型。
///
/// 这是一组通用能力，不是 ChatAgent 私有字段。前台聊天可以拿到完整
/// 装配面；后台 Agent 也拥有同一组槽位，只是按职责收窄权限。
enum AgentContextAssemblyPermission {
  roleCard,
  sillyTavernPreset,
  promptOrder,
  lorebook,
  memory,
  conversationWindow,
  runtimeFacts,
  regexTransform,
  extensionPrompt,
  toolPolicy,
  outputContract,
  providerRenderer,
}

extension AgentContextAssemblyPermissionX on AgentContextAssemblyPermission {
  String get id {
    switch (this) {
      case AgentContextAssemblyPermission.roleCard:
        return 'role_card';
      case AgentContextAssemblyPermission.sillyTavernPreset:
        return 'silly_tavern_preset';
      case AgentContextAssemblyPermission.promptOrder:
        return 'prompt_order';
      case AgentContextAssemblyPermission.lorebook:
        return 'lorebook';
      case AgentContextAssemblyPermission.memory:
        return 'memory';
      case AgentContextAssemblyPermission.conversationWindow:
        return 'conversation_window';
      case AgentContextAssemblyPermission.runtimeFacts:
        return 'runtime_facts';
      case AgentContextAssemblyPermission.regexTransform:
        return 'regex_transform';
      case AgentContextAssemblyPermission.extensionPrompt:
        return 'extension_prompt';
      case AgentContextAssemblyPermission.toolPolicy:
        return 'tool_policy';
      case AgentContextAssemblyPermission.outputContract:
        return 'output_contract';
      case AgentContextAssemblyPermission.providerRenderer:
        return 'provider_renderer';
    }
  }
}

/// 常用上下文装配权限集合。
abstract final class AgentContextAssemblyPermissions {
  static const fullChat = <AgentContextAssemblyPermission>{
    AgentContextAssemblyPermission.roleCard,
    AgentContextAssemblyPermission.sillyTavernPreset,
    AgentContextAssemblyPermission.promptOrder,
    AgentContextAssemblyPermission.lorebook,
    AgentContextAssemblyPermission.memory,
    AgentContextAssemblyPermission.conversationWindow,
    AgentContextAssemblyPermission.runtimeFacts,
    AgentContextAssemblyPermission.regexTransform,
    AgentContextAssemblyPermission.extensionPrompt,
    AgentContextAssemblyPermission.toolPolicy,
    AgentContextAssemblyPermission.outputContract,
    AgentContextAssemblyPermission.providerRenderer,
  };

  static const proactiveSpecialized = <AgentContextAssemblyPermission>{
    AgentContextAssemblyPermission.roleCard,
    AgentContextAssemblyPermission.sillyTavernPreset,
    AgentContextAssemblyPermission.promptOrder,
    AgentContextAssemblyPermission.lorebook,
    AgentContextAssemblyPermission.memory,
    AgentContextAssemblyPermission.conversationWindow,
    AgentContextAssemblyPermission.runtimeFacts,
    AgentContextAssemblyPermission.regexTransform,
    AgentContextAssemblyPermission.toolPolicy,
    AgentContextAssemblyPermission.outputContract,
    AgentContextAssemblyPermission.providerRenderer,
  };

  static const analyzerSpecialized = <AgentContextAssemblyPermission>{
    AgentContextAssemblyPermission.memory,
    AgentContextAssemblyPermission.conversationWindow,
    AgentContextAssemblyPermission.runtimeFacts,
    AgentContextAssemblyPermission.toolPolicy,
    AgentContextAssemblyPermission.outputContract,
    AgentContextAssemblyPermission.providerRenderer,
  };

  static const memorySpecialized = <AgentContextAssemblyPermission>{
    AgentContextAssemblyPermission.memory,
    AgentContextAssemblyPermission.conversationWindow,
    AgentContextAssemblyPermission.runtimeFacts,
    AgentContextAssemblyPermission.toolPolicy,
    AgentContextAssemblyPermission.outputContract,
    AgentContextAssemblyPermission.providerRenderer,
  };

  static const rendererSpecialized = <AgentContextAssemblyPermission>{
    AgentContextAssemblyPermission.runtimeFacts,
    AgentContextAssemblyPermission.toolPolicy,
    AgentContextAssemblyPermission.outputContract,
  };
}

/// Agent 允许产出的标准输出通道。
enum AgentOutputChannel {
  text,
  ttsTag,
  imageTag,
  toolCall,
  json,
  triggerEvent,
}

extension AgentOutputChannelX on AgentOutputChannel {
  String get id {
    switch (this) {
      case AgentOutputChannel.text:
        return 'text';
      case AgentOutputChannel.ttsTag:
        return 'tts_tag';
      case AgentOutputChannel.imageTag:
        return 'image_tag';
      case AgentOutputChannel.toolCall:
        return 'tool_call';
      case AgentOutputChannel.json:
        return 'json';
      case AgentOutputChannel.triggerEvent:
        return 'trigger_event';
    }
  }
}

/// 模型输出契约。
///
/// `<tts>` / `<image>` 属于输出契约，不是上下文真相源。
class AgentOutputContract {
  final Set<AgentOutputChannel> channels;
  final String? instruction;

  const AgentOutputContract({
    this.channels = const <AgentOutputChannel>{AgentOutputChannel.text},
    this.instruction,
  });

  static const standardChat = AgentOutputContract(
    channels: <AgentOutputChannel>{
      AgentOutputChannel.text,
      AgentOutputChannel.ttsTag,
      AgentOutputChannel.imageTag,
      AgentOutputChannel.toolCall,
    },
  );

  static const analyzerJson = AgentOutputContract(
    channels: <AgentOutputChannel>{
      AgentOutputChannel.json,
      AgentOutputChannel.toolCall,
    },
  );

  bool allows(AgentOutputChannel channel) => channels.contains(channel);

  AgentOutputContract copyWith({
    Set<AgentOutputChannel>? channels,
    String? instruction,
    bool clearInstruction = false,
  }) {
    return AgentOutputContract(
      channels: channels ?? this.channels,
      instruction: clearInstruction ? null : (instruction ?? this.instruction),
    );
  }
}

/// 本次运行需要启用的上下文层及其优先级。
class ContextProfile {
  final List<AgentContextLayer> layers;
  final Set<AgentContextAssemblyPermission> assemblyPermissions;
  final Map<AgentContextLayer, int> priorityByLayer;
  final int? tokenBudget;
  final bool traceAssembly;

  const ContextProfile({
    this.layers = const <AgentContextLayer>[
      AgentContextLayer.identity,
      AgentContextLayer.memory,
      AgentContextLayer.conversationWindow,
      AgentContextLayer.runtimeFacts,
      AgentContextLayer.capabilityBoundary,
      AgentContextLayer.outputContract,
    ],
    this.assemblyPermissions = AgentContextAssemblyPermissions.fullChat,
    this.priorityByLayer = const <AgentContextLayer, int>{},
    this.tokenBudget,
    this.traceAssembly = true,
  });

  static const standardChat = ContextProfile(
    assemblyPermissions: AgentContextAssemblyPermissions.fullChat,
  );

  static const backgroundAnalyzer = ContextProfile(
    layers: <AgentContextLayer>[
      AgentContextLayer.identity,
      AgentContextLayer.conversationWindow,
      AgentContextLayer.runtimeFacts,
      AgentContextLayer.capabilityBoundary,
      AgentContextLayer.outputContract,
    ],
    assemblyPermissions: AgentContextAssemblyPermissions.analyzerSpecialized,
  );

  bool includes(AgentContextLayer layer) => layers.contains(layer);

  bool canAssemble(AgentContextAssemblyPermission permission) {
    return assemblyPermissions.contains(permission);
  }

  int priorityOf(AgentContextLayer layer) => priorityByLayer[layer] ?? 100;

  List<AgentContextLayer> get orderedLayers {
    final ordered = List<AgentContextLayer>.from(layers);
    ordered.sort((a, b) => priorityOf(a).compareTo(priorityOf(b)));
    return ordered;
  }

  ContextProfile copyWith({
    List<AgentContextLayer>? layers,
    Set<AgentContextAssemblyPermission>? assemblyPermissions,
    Map<AgentContextLayer, int>? priorityByLayer,
    int? tokenBudget,
    bool clearTokenBudget = false,
    bool? traceAssembly,
  }) {
    return ContextProfile(
      layers: layers ?? this.layers,
      assemblyPermissions: assemblyPermissions ?? this.assemblyPermissions,
      priorityByLayer: priorityByLayer ?? this.priorityByLayer,
      tokenBudget: clearTokenBudget ? null : (tokenBudget ?? this.tokenBudget),
      traceAssembly: traceAssembly ?? this.traceAssembly,
    );
  }
}

/// 统一 Agent 定义。
class AgentDefinition {
  final String id;
  final String name;
  final String objective;
  final AgentTriggerKind triggerKind;
  final AgentKind agentKind;
  final String? contextRecipeId;
  final ContextProfile contextProfile;
  final AgentOutputContract outputContract;
  final List<String> allowedToolNames;
  final AgentDeliveryChannelKind deliveryChannel;
  final AgentTraceKind traceKind;
  final String? modelRef;
  final double? temperature;
  final int maxRounds;

  const AgentDefinition({
    required this.id,
    required this.name,
    required this.objective,
    this.triggerKind = AgentTriggerKind.userMessage,
    this.agentKind = AgentKind.chat,
    this.contextRecipeId,
    this.contextProfile = ContextProfile.standardChat,
    this.outputContract = AgentOutputContract.standardChat,
    this.allowedToolNames = const <String>[],
    this.deliveryChannel = AgentDeliveryChannelKind.foregroundConversation,
    this.traceKind = AgentTraceKind.foreground,
    this.modelRef,
    this.temperature,
    this.maxRounds = 5,
  });

  AgentDefinition copyWith({
    String? id,
    String? name,
    String? objective,
    AgentTriggerKind? triggerKind,
    AgentKind? agentKind,
    String? contextRecipeId,
    bool clearContextRecipeId = false,
    ContextProfile? contextProfile,
    AgentOutputContract? outputContract,
    List<String>? allowedToolNames,
    AgentDeliveryChannelKind? deliveryChannel,
    AgentTraceKind? traceKind,
    String? modelRef,
    bool clearModelRef = false,
    double? temperature,
    bool clearTemperature = false,
    int? maxRounds,
  }) {
    return AgentDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      objective: objective ?? this.objective,
      triggerKind: triggerKind ?? this.triggerKind,
      agentKind: agentKind ?? this.agentKind,
      contextRecipeId: clearContextRecipeId
          ? null
          : (contextRecipeId ?? this.contextRecipeId),
      contextProfile: contextProfile ?? this.contextProfile,
      outputContract: outputContract ?? this.outputContract,
      allowedToolNames: allowedToolNames ?? this.allowedToolNames,
      deliveryChannel: deliveryChannel ?? this.deliveryChannel,
      traceKind: traceKind ?? this.traceKind,
      modelRef: clearModelRef ? null : (modelRef ?? this.modelRef),
      temperature: clearTemperature ? null : (temperature ?? this.temperature),
      maxRounds: maxRounds ?? this.maxRounds,
    );
  }
}

/// 一次 Agent 运行请求。
///
/// 前台聊天、后台扫描、主动关怀、记忆总结都应先被归一化成
/// AgentRunRequest，再交给 AgentScheduler / AgentRuntime 执行。
class AgentRunRequest {
  final String runId;
  final String agentId;
  final AgentKind agentKind;
  final AgentTriggerKind triggerKind;
  final String? conversationId;
  final String? contactId;
  final Object? triggerPayload;
  final List<Message> inputMessages;
  final Map<String, Object?> contextOverrides;
  final AgentDeliveryChannelKind deliveryChannel;
  final AgentTraceKind traceKind;
  final bool dryRun;
  final bool preview;
  final Map<String, Object?> metadata;

  const AgentRunRequest({
    required this.runId,
    required this.agentId,
    required this.agentKind,
    required this.triggerKind,
    this.conversationId,
    this.contactId,
    this.triggerPayload,
    this.inputMessages = const <Message>[],
    this.contextOverrides = const <String, Object?>{},
    required this.deliveryChannel,
    required this.traceKind,
    this.dryRun = false,
    this.preview = false,
    this.metadata = const <String, Object?>{},
  });

  Map<String, Object?> toTracePayload() {
    return <String, Object?>{
      'runId': runId,
      'agentId': agentId,
      'agentKind': agentKind.id,
      'triggerKind': triggerKind.id,
      'conversationId': conversationId,
      'contactId': contactId,
      'inputMessageIds': inputMessages.map((message) => message.id).toList(),
      'deliveryChannel': deliveryChannel.id,
      'traceKind': traceKind.id,
      'dryRun': dryRun,
      'preview': preview,
      'contextOverrideKeys': contextOverrides.keys.toList(),
      'triggerPayloadType': triggerPayload?.runtimeType.toString(),
      'metadata': metadata,
    };
  }
}

/// AgentRuntime 对外暴露的运行状态。
enum AgentRunStatus {
  completed,
  skipped,
  failed,
}

extension AgentRunStatusX on AgentRunStatus {
  String get id {
    switch (this) {
      case AgentRunStatus.completed:
        return 'completed';
      case AgentRunStatus.skipped:
        return 'skipped';
      case AgentRunStatus.failed:
        return 'failed';
    }
  }
}

/// AgentRuntime 的统一运行结果。
class AgentRunResult {
  final AgentRunRequest request;
  final AgentRunStatus status;
  final Object? error;
  final Map<String, Object?> metadata;

  const AgentRunResult({
    required this.request,
    required this.status,
    this.error,
    this.metadata = const <String, Object?>{},
  });

  Map<String, Object?> toTracePayload() {
    return <String, Object?>{
      ...request.toTracePayload(),
      'status': status.id,
      'error': error?.toString(),
      'resultMetadata': metadata,
    };
  }
}

/// 统一 Agent 执行器。
abstract interface class AgentRuntime<TRequest extends AgentRunRequest,
    TResult extends AgentRunResult> {
  Future<TResult> run(TRequest request);
}

/// 统一 Agent 调度器。
abstract interface class AgentScheduler<TRequest extends AgentRunRequest,
    TResult extends AgentRunResult> {
  Future<TResult> submit(TRequest request);
}

/// 第一阶段直通调度器：先统一入口形态，不改变既有执行行为。
class DirectAgentScheduler<TRequest extends AgentRunRequest,
        TResult extends AgentRunResult>
    implements AgentScheduler<TRequest, TResult> {
  final AgentRuntime<TRequest, TResult> runtime;

  const DirectAgentScheduler(this.runtime);

  @override
  Future<TResult> submit(TRequest request) => runtime.run(request);
}

/// 标准化输出事件类型。
enum AgentOutputEventKind {
  textDelta,
  textFinal,
  ttsRequest,
  imageRequest,
  toolInvocation,
  triggerCandidate,
  memoryWriteCandidate,
  jsonDecision,
  error,
}

extension AgentOutputEventKindX on AgentOutputEventKind {
  String get id {
    switch (this) {
      case AgentOutputEventKind.textDelta:
        return 'text_delta';
      case AgentOutputEventKind.textFinal:
        return 'text_final';
      case AgentOutputEventKind.ttsRequest:
        return 'tts_request';
      case AgentOutputEventKind.imageRequest:
        return 'image_request';
      case AgentOutputEventKind.toolInvocation:
        return 'tool_invocation';
      case AgentOutputEventKind.triggerCandidate:
        return 'trigger_candidate';
      case AgentOutputEventKind.memoryWriteCandidate:
        return 'memory_write_candidate';
      case AgentOutputEventKind.jsonDecision:
        return 'json_decision';
      case AgentOutputEventKind.error:
        return 'error';
    }
  }
}

/// OutputPipeline 产出的标准事件。
class AgentOutputEvent {
  final String id;
  final String runId;
  final AgentOutputEventKind kind;
  final Object? payload;
  final Map<String, Object?> metadata;

  const AgentOutputEvent({
    required this.id,
    required this.runId,
    required this.kind,
    this.payload,
    this.metadata = const <String, Object?>{},
  });

  Map<String, Object?> toTracePayload() {
    return <String, Object?>{
      'id': id,
      'runId': runId,
      'kind': kind.id,
      'payloadType': payload?.runtimeType.toString(),
      'metadata': metadata,
    };
  }
}

/// 标准投递通道。
abstract interface class AgentDeliveryChannel<TEvent extends AgentOutputEvent> {
  AgentDeliveryChannelKind get kind;

  Future<void> deliver(TEvent event);
}

/// 上下文节点类型。
///
/// 这是对 SillyTavern `prompts + prompt_order + marker` 架子的内部抽象：
/// 静态 prompt、动态 marker、聊天历史窗口、扩展注入都先表现为有序节点，
/// 最后再由 renderer 输出成模型 messages。
enum AgentContextNodeKind {
  staticPrompt,
  marker,
  chatHistory,
  extensionPrompt,
  outputContract,
}

extension AgentContextNodeKindX on AgentContextNodeKind {
  String get id {
    switch (this) {
      case AgentContextNodeKind.staticPrompt:
        return 'static_prompt';
      case AgentContextNodeKind.marker:
        return 'marker';
      case AgentContextNodeKind.chatHistory:
        return 'chat_history';
      case AgentContextNodeKind.extensionPrompt:
        return 'extension_prompt';
      case AgentContextNodeKind.outputContract:
        return 'output_contract';
    }
  }
}

/// 有序上下文节点。
class AgentContextNode {
  final String id;
  final String name;
  final AgentContextNodeKind kind;
  final String role;
  final String content;
  final AgentContextLayer? layer;
  final bool enabled;
  final bool marker;
  final int priority;
  final Map<String, Object?> metadata;

  const AgentContextNode({
    required this.id,
    required this.name,
    required this.kind,
    this.role = 'system',
    this.content = '',
    this.layer,
    this.enabled = true,
    this.marker = false,
    this.priority = 100,
    this.metadata = const <String, Object?>{},
  });

  bool get hasContent => content.trim().isNotEmpty;

  AgentContextNode copyWith({
    String? id,
    String? name,
    AgentContextNodeKind? kind,
    String? role,
    String? content,
    AgentContextLayer? layer,
    bool clearLayer = false,
    bool? enabled,
    bool? marker,
    int? priority,
    Map<String, Object?>? metadata,
  }) {
    return AgentContextNode(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      role: role ?? this.role,
      content: content ?? this.content,
      layer: clearLayer ? null : (layer ?? this.layer),
      enabled: enabled ?? this.enabled,
      marker: marker ?? this.marker,
      priority: priority ?? this.priority,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// 一套可排序、可注入的上下文配方。
class AgentContextRecipe {
  final String id;
  final String name;
  final List<AgentContextNode> nodes;
  final Map<String, Object?> metadata;

  const AgentContextRecipe({
    required this.id,
    required this.name,
    required this.nodes,
    this.metadata = const <String, Object?>{},
  });

  List<AgentContextNode> get enabledNodes =>
      nodes.where((node) => node.enabled).toList(growable: false);
}

/// 最终传给模型前的消息节点。
class AgentRenderedMessage {
  final String role;
  final Object content;
  final List<String> contextNodeIds;
  final Map<String, Object?> metadata;

  const AgentRenderedMessage({
    required this.role,
    required this.content,
    this.contextNodeIds = const <String>[],
    this.metadata = const <String, Object?>{},
  });

  bool get isEmpty {
    final value = content;
    if (value is String) {
      return value.trim().isEmpty;
    }
    if (value is Iterable) {
      return value.isEmpty;
    }
    return false;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'role': role,
      'content': content,
      'contextNodeIds': contextNodeIds,
      'metadata': metadata,
    };
  }
}

/// 一段已归类的上下文材料。
class AgentContextEntry {
  final String id;
  final AgentContextLayer layer;
  final String content;
  final int? priority;
  final Map<String, Object?> metadata;

  const AgentContextEntry({
    required this.id,
    required this.layer,
    required this.content,
    this.priority,
    this.metadata = const <String, Object?>{},
  });

  bool get isEmpty => content.trim().isEmpty;

  int priorityIn(ContextProfile profile) =>
      priority ?? profile.priorityOf(layer);
}

/// 上下文组装后的结果。
class AgentContextAssembly {
  final AgentDefinition definition;
  final String systemPrompt;
  final List<Message> messages;
  final List<AgentContextEntry> entries;
  final AgentContextRecipe? contextRecipe;
  final List<AgentContextNode> contextNodes;
  final List<AgentRenderedMessage> renderedMessages;
  final Map<String, Object?> metadata;

  const AgentContextAssembly({
    required this.definition,
    required this.systemPrompt,
    required this.messages,
    required this.entries,
    this.contextRecipe,
    this.contextNodes = const <AgentContextNode>[],
    this.renderedMessages = const <AgentRenderedMessage>[],
    this.metadata = const <String, Object?>{},
  });

  Map<String, Object?> toTracePayload() {
    return <String, Object?>{
      'agentId': definition.id,
      'agentName': definition.name,
      'agentKind': definition.agentKind.id,
      'triggerKind': definition.triggerKind.id,
      'deliveryChannel': definition.deliveryChannel.id,
      'traceKind': definition.traceKind.id,
      'contextRecipeId': contextRecipe?.id ?? definition.contextRecipeId,
      'contextLayers': entries.map((entry) => entry.layer.id).toList(),
      'contextEntryIds': entries.map((entry) => entry.id).toList(),
      'contextNodeIds': contextNodes.map((node) => node.id).toList(),
      'renderedMessagesCount': renderedMessages.length,
      'outputChannels': definition.outputContract.channels
          .map((channel) => channel.id)
          .toList(),
      'messagesCount': messages.length,
      'systemPromptLength': systemPrompt.length,
      'metadata': metadata,
    };
  }
}
