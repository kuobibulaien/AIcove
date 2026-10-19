library;

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancellation;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../agent_plugins/plugin_response.dart';
import 'chat_send_api_runner.dart';
import 'chat_types.dart';

/// Compile-time switches for the agent kernel (ADR0064, batch 1).
/// Foreground chat runs on the kernel by default since 2026-10-12 and
/// background agents since 2026-10-13. Build with
/// `--dart-define=AICOVE_AGENT_KERNEL_CHAT=false` or
/// `--dart-define=AICOVE_AGENT_KERNEL_BG=false` to fall back to the legacy
/// runner.
const bool kAgentKernelBackground = bool.fromEnvironment(
  'AICOVE_AGENT_KERNEL_BG',
  defaultValue: true,
);
const bool kAgentKernelChat = bool.fromEnvironment(
  'AICOVE_AGENT_KERNEL_CHAT',
  defaultValue: true,
);

/// Model call and tool loop for one request. Implemented by the legacy
/// [ChatSendApiRunner] and the kernel-backed [KernelApiRunner].
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
    int maxRounds = 5,
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

ApiRunner createApiRunner({required bool useKernel}) =>
    useKernel ? const KernelApiRunner() : const ChatSendApiRunner();
