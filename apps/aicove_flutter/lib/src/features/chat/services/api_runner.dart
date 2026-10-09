library;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart';
import '../../plugins/domain/handlers/ai_tool.dart';
import '../../plugins/domain/plugin.dart';
import 'chat_send_api_runner.dart';
import 'chat_types.dart';

/// Compile-time switches for the agent kernel (ADR0064, batch 1).
/// Off by default; rebuild without the define to fall back.
const bool kAgentKernelBackground =
    bool.fromEnvironment('AICOVE_AGENT_KERNEL_BG');
const bool kAgentKernelChat = bool.fromEnvironment('AICOVE_AGENT_KERNEL_CHAT');

/// Model call and tool loop for one request. Implemented by the legacy
/// [ChatSendApiRunner] and the kernel-backed [KernelApiRunner].
abstract interface class ApiRunner {
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required List<Plugin> effectivePlugins,
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
  });
}

ApiRunner createApiRunner({required bool useKernel}) =>
    useKernel ? const KernelApiRunner() : const ChatSendApiRunner();
