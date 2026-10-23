library;

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../agent_plugins/plugin_response.dart';
import 'chat_send_api_runner.dart';
import 'chat_types.dart';

/// Single execution contract shared by foreground and background agents.
abstract interface class ApiRunner {
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<PluginResponseProcessor> responseProcessors,

    /// Tools the model may call; null uses `config.boundTools`.
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

    /// Stops the run between stages; tools check it before committing.
    KernelCancellation? cancellation,
  });
}

ApiRunner createApiRunner() => const KernelApiRunner();
