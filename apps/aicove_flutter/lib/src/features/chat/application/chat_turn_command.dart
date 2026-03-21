library;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart' show TraceContext;
import '../domain/conversation.dart';
import '../domain/message.dart';

enum ChatTurnExecutionMode { nonStreaming, streaming }

class ChatTurnCommand {
  const ChatTurnCommand({
    required this.conversation,
    required this.userMessage,
    required this.sessionId,
    required this.apiText,
    required this.traceContext,
    required this.executionMode,
    this.trace,
  });

  const ChatTurnCommand.nonStreaming({
    required this.conversation,
    required this.userMessage,
    required this.sessionId,
    required this.apiText,
    required this.traceContext,
    this.trace,
  }) : executionMode = ChatTurnExecutionMode.nonStreaming;

  const ChatTurnCommand.streaming({
    required this.conversation,
    required this.userMessage,
    required this.sessionId,
    required this.apiText,
    required this.traceContext,
    this.trace,
  }) : executionMode = ChatTurnExecutionMode.streaming;

  final Conversation conversation;
  final Message userMessage;
  final String sessionId;
  final String apiText;
  final TraceContext? traceContext;
  final ChatTurnExecutionMode executionMode;
  final TraceLogger? trace;

  bool get isStreaming => executionMode == ChatTurnExecutionMode.streaming;
}
