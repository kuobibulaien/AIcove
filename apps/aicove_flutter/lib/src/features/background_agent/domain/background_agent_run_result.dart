import '../../chat/domain/message.dart';
import '../../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;

class BackgroundAgentRunResult {
  final String sessionId;
  final String replyText;
  final String processedText;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolCall> toolCalls;
  final List<ToolResult> rawToolResults;
  final List<Message> usedMessages;

  const BackgroundAgentRunResult({
    required this.sessionId,
    required this.replyText,
    required this.processedText,
    required this.toolResults,
    required this.toolCalls,
    required this.rawToolResults,
    required this.usedMessages,
  });

  String get text =>
      processedText.trim().isNotEmpty ? processedText : replyText;
}
