library;

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
/// 触发方式不应该决定上下文组装规则；聊天、后台扫描、主动回复
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
/// Parameters of the conversation-window layer: how many recent messages,
/// which roles, and whether to stamp times. Formerly the background agent's
/// own `BackgroundContextSpec` (ADR0060, batch 2 plan §3.7).
class ConversationWindowSpec {
  final int lastMessages;
  final bool includeUser;
  final bool includeAssistant;
  final bool includeSystem;
  final bool includeTimestamps;

  const ConversationWindowSpec({
    this.lastMessages = 10,
    this.includeUser = true,
    this.includeAssistant = true,
    this.includeSystem = false,
    this.includeTimestamps = false,
  });

  bool includesRole(String role) {
    switch (role.trim().toLowerCase()) {
      case 'user':
        return includeUser;
      case 'assistant':
        return includeAssistant;
      case 'system':
        return includeSystem;
      default:
        return false;
    }
  }

  int get normalizedLastMessages => lastMessages < 1 ? 1 : lastMessages;

  ConversationWindowSpec copyWith({
    int? lastMessages,
    bool? includeUser,
    bool? includeAssistant,
    bool? includeSystem,
    bool? includeTimestamps,
  }) {
    return ConversationWindowSpec(
      lastMessages: lastMessages ?? this.lastMessages,
      includeUser: includeUser ?? this.includeUser,
      includeAssistant: includeAssistant ?? this.includeAssistant,
      includeSystem: includeSystem ?? this.includeSystem,
      includeTimestamps: includeTimestamps ?? this.includeTimestamps,
    );
  }
}

class ContextProfile {
  final List<AgentContextLayer> layers;
  final Map<AgentContextLayer, int> priorityByLayer;
  final int? tokenBudget;
  final bool traceAssembly;
  final ConversationWindowSpec conversationWindow;

  const ContextProfile({
    this.layers = const <AgentContextLayer>[
      AgentContextLayer.identity,
      AgentContextLayer.memory,
      AgentContextLayer.conversationWindow,
      AgentContextLayer.runtimeFacts,
      AgentContextLayer.capabilityBoundary,
      AgentContextLayer.outputContract,
    ],
    this.priorityByLayer = const <AgentContextLayer, int>{},
    this.tokenBudget,
    this.traceAssembly = true,
    this.conversationWindow = const ConversationWindowSpec(),
  });

  static const standardChat = ContextProfile();

  static const backgroundAnalyzer = ContextProfile(
    layers: <AgentContextLayer>[
      AgentContextLayer.identity,
      AgentContextLayer.conversationWindow,
      AgentContextLayer.runtimeFacts,
      AgentContextLayer.capabilityBoundary,
      AgentContextLayer.outputContract,
    ],
  );

  /// A background analyzer reading [window] of the conversation.
  static ContextProfile background(ConversationWindowSpec window) =>
      backgroundAnalyzer.copyWith(conversationWindow: window);

  bool includes(AgentContextLayer layer) => layers.contains(layer);

  int priorityOf(AgentContextLayer layer) => priorityByLayer[layer] ?? 100;

  List<AgentContextLayer> get orderedLayers {
    final ordered = List<AgentContextLayer>.from(layers);
    ordered.sort((a, b) => priorityOf(a).compareTo(priorityOf(b)));
    return ordered;
  }

  ContextProfile copyWith({
    List<AgentContextLayer>? layers,
    Map<AgentContextLayer, int>? priorityByLayer,
    int? tokenBudget,
    bool clearTokenBudget = false,
    bool? traceAssembly,
    ConversationWindowSpec? conversationWindow,
  }) {
    return ContextProfile(
      layers: layers ?? this.layers,
      priorityByLayer: priorityByLayer ?? this.priorityByLayer,
      tokenBudget: clearTokenBudget ? null : (tokenBudget ?? this.tokenBudget),
      traceAssembly: traceAssembly ?? this.traceAssembly,
      conversationWindow: conversationWindow ?? this.conversationWindow,
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

  /// How tool calls of this agent are authorized (batch 2 plan §3.4).
  final AgentToolAuthorization toolPolicy;

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
    this.toolPolicy = AgentToolAuthorization.allowAll,
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
    AgentToolAuthorization? toolPolicy,
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
      toolPolicy: toolPolicy ?? this.toolPolicy,
    );
  }
}

/// 工具授权模式（第二批方案 3.4）。
enum AgentToolAuthorization {
  /// 全部放行：普通聊天，行为与闸门接入前一致。
  allowAll,

  /// 手动允许：只读诊断直接执行，其余每次询问。
  manual,

  /// 无限制：全部放行；可撤销修改照样写撤销记录。
  unrestricted,
}
