library;

import '../../../core/api/tool_media.dart';
import '../../../core/api/request_control.dart';
import '../../plugins/domain/handlers/tool_schema_validator.dart';
import '../../plugins/data/tool_result_store.dart';
import 'dart:async';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' as kernel;
import '../../agent_context/domain/preset_script_runtime.dart';
import '../../agent_context/infrastructure/quickjs_preset_runtime.dart';
import '../../context/domain/context_window_policy.dart';
import '../../../core/media/media_resolver.dart';
import 'dart:convert';
import 'dart:io';
import '../../../core/models/image_generation_snapshot.dart';

import '../../plugins/domain/handlers/ai_tool.dart';
import '../../agent_plugins/plugin_response.dart';
import '../../agent_plugins/tool_policy.dart';
import '../../agent_context/domain/agent_runtime_contracts.dart'
    show AgentToolAuthorization;
import '../../plugins/domain/plugin.dart';
import '../../plugins/domain/plugin_content.dart';
import '../../plugins/plugin_content_tags.dart';
import '../../stickers/sticker_tag.dart';
import '../../../core/api/agent_api.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ProviderAdapter, ToolCall, ToolResult, ProviderChatRequestOptions;
import '../../../core/api/providers/provider_adapter_factory.dart';
import '../../../core/api_logger.dart';
import '../../../core/app_logger.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/utils/mime_utils.dart';
import '../../settings/settings_models.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import '../../agent_context/domain/silly_tavern_regex_processor.dart';
import 'api_runner.dart';
import 'chat_types.dart';
import 'stream_monitor_service.dart';

part 'chat_send_api_runner_tool_support.dart';
part 'chat_send_api_runner_text_support.dart';
part 'chat_send_api_runner_kernel.dart';
part 'chat_run_product_stages.dart';

typedef _AgentClientFactory = AgentApiClient Function(Duration timeout);

/// Compatibility facade for historical callers. All execution uses AgentLoop.
class ChatSendApiRunner implements ApiRunner {
  const ChatSendApiRunner() : _agentClientFactory = _defaultAgentClientFactory;

  ChatSendApiRunner.withAgentClientFactory({
    required AgentApiClient Function(Duration timeout) agentClientFactory,
  }) : _agentClientFactory = agentClientFactory;

  static const SillyTavernRegexProcessor _presetRegexProcessor =
      SillyTavernRegexProcessor();
  static const String _logTag = 'ChatSendService';
  static const String _stableDrawImageReviewPrefix =
      '__AICOVE_DRAW_IMAGE_REVIEW__';
  static String get _stableDrawImageReviewInstruction =>
      PromptBuiltinDefaults.requireTemplate(
        'chat.draw_image.stable_review_instruction',
      );
  static final RegExp _imagePlaceholderRegex = RegExp(
    r'(?:<image>\s*</image>|\[(?:图片|image)(?:\s*:[^\]]*)?\])',
    caseSensitive: false,
  );
  static AgentApiClient _defaultAgentClientFactory(Duration timeout) =>
      AgentApiClient(timeout: timeout);

  final _AgentClientFactory _agentClientFactory;

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<PluginResponseProcessor> responseProcessors,
    List<AITool>? availableTools,
    String? turnId,
    TraceLogger? trace,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
    TraceContext? traceContext,
    kernel.KernelCancellation? cancellation,
  }) async {
    return KernelApiRunner._persistentToolOutput(
      _agentClientFactory,
    ).executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: userText,
      responseProcessors: responseProcessors,
      availableTools: availableTools,
      turnId: turnId,
      trace: trace,
      onToolExecuting: onToolExecuting,
      enableStreaming: enableStreaming,
      onStreamTextDelta: onStreamTextDelta,
      onStreamTextReset: onStreamTextReset,
      onStreamToolCallObserved: onStreamToolCallObserved,
      onStreamingFallback: onStreamingFallback,
      traceContext: traceContext,
      cancellation: cancellation,
    );
  }
}
