/// 聊天辅助数据类型
///
/// 从 chat_actions.dart 提取的内部数据类，改为公开类型以便服务间共享
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import '../../agent_context/domain/preset_script_runtime.dart';

import '../../context/domain/context_summary.dart' show RuntimeContextPort;

import 'dart:async';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;
import '../../plugins/data/tool_result_store.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../../agent_plugins/plugin_response.dart';
import '../../agent_plugins/tool_policy.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/image/image_config.dart';
import '../../plugins/tts/voice_request.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../settings/app_settings.dart';
import '../../agent_context/domain/silly_tavern_preset.dart'
    show SillyTavernRegexScript;
import '../../../core/api/providers/provider_adapter.dart'
    show ProviderChatRequestOptions, ToolCall, ToolResult;
import '../../observability/trace_models.dart' show TraceContext;

const String _kProviderRefreshDependencyChangedMessage =
    'Cannot use ref functions after the dependency of a provider changed';
const String _kProviderRefreshRebuiltMessage = 'before the provider rebuilt';
const String _kProviderRefreshDidChangeDependencyToken =
    '!_didChangeDependency';

/// 是否命中了 Riverpod 依赖切换窗口的瞬时错误。
///
/// 当前 Riverpod 没有暴露稳定的专用异常类型，这里统一收敛为：
/// 1) 标准 ref/dependency changed 文案
/// 2) `!_didChangeDependency` 断言变体
///
/// 这样至少可以把运行时的字符串识别集中到一处，避免多份判断漂移。
bool isProviderRefreshTimingError(Object error) {
  final normalized = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return false;
  }
  if (normalized.contains(_kProviderRefreshDependencyChangedMessage) &&
      normalized.contains(_kProviderRefreshRebuiltMessage)) {
    return true;
  }
  return normalized.contains(_kProviderRefreshDidChangeDependencyToken);
}

/// 发送请求参数数据类
class SendRequest {
  final Conversation conversation;
  final String? text;
  final String? imagePath;
  final Message userMessage;

  const SendRequest({
    required this.conversation,
    this.text,
    this.imagePath,
    required this.userMessage,
  });

  String get convId => conversation.id;
  String get displayText => text ?? (imagePath != null ? '[图片]' : '');
}

/// 工具音频结果
class ToolAudioResult {
  final String audioUrl;
  final String text;

  const ToolAudioResult({required this.audioUrl, required this.text});
}

enum ApiRunStatus { completed, truncated, waitingForUser, cancelled, failed }

/// API 调用结果
class ApiCallResult {
  final ApiRunStatus status;
  final String? stopReason;
  final String? lastModelText;
  final List<Map<String,dynamic>> runningMessages;
  final String rawReplyText;
  final String replyText;
  final String processedText;
  final List<Map<String, dynamic>> hiddenThoughtParts;
  final List<PluginEvent> pluginEvents;
  final List<PluginContent> pluginContents;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolAudioResult> toolAudioResults;
  final List<ToolCall> toolCalls;
  final List<ToolResult> rawToolResults;

  /// 本次回复各轮的模型原生思考，按顺序拼好；只用于展示，不进上下文。
  final String reasoning;

  /// 调过工具的回复按轮拆开的展示结构（最后一轮是正文），供列表按真实先后
  /// 穿插话术与工具调用；没调工具或旧 runner 时为空，按合并文字展示。
  final List<ReplyRound> replyRounds;

  const ApiCallResult({
    this.status = ApiRunStatus.completed,
    this.stopReason,
    this.lastModelText,
    this.runningMessages = const [],
    String? rawReplyText,
    required this.replyText,
    required this.processedText,
    this.hiddenThoughtParts = const [],
    required this.pluginEvents,
    this.pluginContents = const [],
    required this.toolResults,
    this.toolAudioResults = const [],
    this.toolCalls = const [],
    this.rawToolResults = const [],
    this.reasoning = '',
    this.replyRounds = const [],
  }) : rawReplyText = rawReplyText ?? replyText;

  bool get hasToolAudio => toolAudioResults.isNotEmpty;
}

/// 工具循环里的一轮：这一轮的思考、话术（已过正则与插件）和调用的工具。
/// 最后一轮是正文，不带工具；工具产出的图片、语音归最后一轮。
class ReplyRound {
  const ReplyRound({
    required this.replyText,
    required this.processedText,
    this.pluginEvents = const [],
    this.pluginContents = const [],
    this.reasoning = '',
    this.toolCallIds = const [],
  });

  final String replyText;
  final String processedText;
  final List<PluginEvent> pluginEvents;
  final List<PluginContent> pluginContents;
  final String reasoning;
  final List<String> toolCallIds;
}

/// 多轮工具循环里每轮的原生思考按顺序拼成一段，轮与轮之间用分隔线隔开。
String joinRoundReasonings(List<String> rounds) => rounds
    .map((round) => round.trim())
    .where((round) => round.isNotEmpty)
    .join('\n\n---\n\n');

/// API 配置参数
class ApiConfig {
  final KernelCancellation? cancellation;
  final ToolResultStore? toolResultStore;
  final String? toolResultOwner;
  final String? Function()? currentWorkspaceId;
  final void Function(bool Function(String) steer)? onRunReady;
  final Future<void> Function(ToolCall call, ToolResult result)? onToolStep;
  final Future<void> Function(List<Map<String,dynamic>> messages)? onTranscript;
  final void Function(String toolName, String progress)? onToolProgress;
  final PresetScriptSnapshot? presetScript;

  /// The preset runtime service from the tavern compatibility plugin; null
  /// when assembled without the plugin runtime (the runner then opens the
  /// default runtime).
  final PresetRuntimeOpener? openPresetRuntime;
  final int? requestInputTokenLimit;
  final RuntimeContextPort? runtimeContext;
  final AppSettings settings;
  final String modelFullId;
  final String providerApiBase;
  final String? providerApiKey;
  final String providerId;
  final String? providerApiKeyItemId;
  final int? providerApiKeyItemIndex;
  final String? providerApiKeyStrategy;
  final Map<String, dynamic> customConfig;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>>? tools;

  /// 与发给模型的 schema 同时生成，闭包固定本次请求的联系人。
  final List<AITool>? boundTools;
  final Set<String>? enabledPluginIds;
  final double? modelTemperature;
  final double? modelTopP;
  final int? modelContextMessageLimit;
  final ProviderChatRequestOptions? providerRequestOptions;
  final List<SillyTavernRegexScript> presetRegexScripts;
  final bool presetRegexAuthorized;
  final bool? presetStreamResponse;
  final TraceContext? traceContext;
  final String? boundImageToolPresetName;
  final String? boundImageArtistPresetName;
  final ImageConfig? drawingConfig;
  final VoiceRequest? voiceRequest;

  /// Reply processors fixed when the request was prepared, so plugin
  /// changes after prepare do not affect this turn.
  final List<PluginResponseProcessor> responseProcessors;

  /// Tool authorization of this run (kernel runner only). Null runs tools
  /// as before the gate existed, which is ordinary chat.
  final AgentToolPolicy? toolPolicy;

  /// 装配时要求延后的插件提醒（时间感知等），按给定时刻现算；null 表示提醒
  /// 已经插进 [messages]。给每轮在不同时刻发出的同一份快照用（通话）。
  final String Function(DateTime requestTime)? reminders;

  const ApiConfig({
    this.cancellation,
    this.toolResultStore,
    this.toolResultOwner,
    this.currentWorkspaceId,
    this.onRunReady,
    this.onToolStep,
    this.onTranscript,
    this.onToolProgress,
    this.presetScript,
    this.openPresetRuntime,
    this.requestInputTokenLimit,
    this.runtimeContext,
    required this.settings,
    required this.modelFullId,
    required this.providerApiBase,
    this.providerApiKey,
    this.providerId = 'openai',
    this.providerApiKeyItemId,
    this.providerApiKeyItemIndex,
    this.providerApiKeyStrategy,
    required this.customConfig,
    required this.messages,
    this.tools,
    this.boundTools,
    this.enabledPluginIds,
    this.modelTemperature,
    this.modelTopP,
    this.modelContextMessageLimit,
    this.providerRequestOptions,
    this.presetRegexScripts = const <SillyTavernRegexScript>[],
    this.presetRegexAuthorized = false,
    this.presetStreamResponse,
    this.traceContext,
    this.boundImageToolPresetName,
    this.boundImageArtistPresetName,
    this.drawingConfig,
    this.voiceRequest,
    this.responseProcessors = const [],
    this.toolPolicy,
    this.reminders,
  });

  double? get effectiveTemperature => modelTemperature ?? settings.temperature;

  /// 在装配结果上换掉消息、工具或请求选项，其余字段原样保留。
  ApiConfig copyWith({
    KernelCancellation? cancellation,
    List<Map<String, dynamic>>? messages,
    bool clearTools = false,
    List<Map<String, dynamic>>? tools,
    List<AITool>? boundTools,
    ProviderChatRequestOptions? providerRequestOptions,
    bool? presetStreamResponse,
    AgentToolPolicy? toolPolicy,
    TraceContext? traceContext,
  }) => ApiConfig(
    cancellation: cancellation ?? this.cancellation,
    toolResultStore: toolResultStore,
    toolResultOwner: toolResultOwner,
    currentWorkspaceId: currentWorkspaceId,
    onRunReady: onRunReady,
    onToolStep: onToolStep,
    onTranscript: onTranscript,
    onToolProgress: onToolProgress,
    presetScript: presetScript,
    openPresetRuntime: openPresetRuntime,
    requestInputTokenLimit: requestInputTokenLimit,
    runtimeContext: runtimeContext,
    settings: settings,
    modelFullId: modelFullId,
    providerApiBase: providerApiBase,
    providerApiKey: providerApiKey,
    providerId: providerId,
    providerApiKeyItemId: providerApiKeyItemId,
    providerApiKeyItemIndex: providerApiKeyItemIndex,
    providerApiKeyStrategy: providerApiKeyStrategy,
    customConfig: customConfig,
    messages: messages ?? this.messages,
    tools: clearTools ? null : (tools ?? this.tools),
    boundTools: clearTools ? null : (boundTools ?? this.boundTools),
    enabledPluginIds: enabledPluginIds,
    modelTemperature: modelTemperature,
    modelTopP: modelTopP,
    modelContextMessageLimit: modelContextMessageLimit,
    providerRequestOptions:
        providerRequestOptions ?? this.providerRequestOptions,
    presetRegexScripts: presetRegexScripts,
    presetRegexAuthorized: presetRegexAuthorized,
    presetStreamResponse: presetStreamResponse ?? this.presetStreamResponse,
    traceContext: traceContext ?? this.traceContext,
    boundImageToolPresetName: boundImageToolPresetName,
    boundImageArtistPresetName: boundImageArtistPresetName,
    drawingConfig: drawingConfig,
    voiceRequest: voiceRequest,
    // A copy must never lose the run's tool gate.
    toolPolicy: toolPolicy ?? this.toolPolicy,
    reminders: reminders,
    responseProcessors: responseProcessors,
  );
}

/// 待处理的 TTS 音频信息
class PendingTtsAudio {
  final String convId;
  final String placeholderId;
  final String? originalText;
  final Completer<TtsAudioResult> completer;

  PendingTtsAudio({
    required this.convId,
    required this.placeholderId,
    this.originalText,
    required this.completer,
  });
}

/// TTS 音频处理结果
class TtsAudioResult {
  final Message? message;
  final bool success;
  final String? error;

  const TtsAudioResult.success(this.message) : success = true, error = null;

  const TtsAudioResult.failure([this.error]) : success = false, message = null;
}

/// 助手消息交付结果
class AssistantDeliveryResult {
  final List<Message> messages;
  final String lastMessagePreview;
  final String? placeholderId;

  const AssistantDeliveryResult({
    required this.messages,
    required this.lastMessagePreview,
    this.placeholderId,
  });
}

/// 助手消息构建结果
class AssistantMessageBuildResult {
  final Message? rawMessage;
  final List<Message> messages;
  final String lastMessageText;

  const AssistantMessageBuildResult({
    this.rawMessage,
    required this.messages,
    required this.lastMessageText,
  });
}
