library;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart' show TraceContext;
import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../services/chat_types.dart'
    show ApiCallResult, ApiConfig, AssistantMessageBuildResult;

abstract interface class ChatHistoryPort {
  Future<List<Message>> loadRawMessages(String conversationId);

  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  });

  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  });

  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  });

  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  });

  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  });
}

abstract interface class ChatSendPort {
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  });

  Future<Message> createUserFileMessage({
    required String filePath,
    String? text,
  });

  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  });

  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  });

  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
    required int limit,
  });

  List<String> buildImageSendModelRefs(AppSettings settings);

  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  });

  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    String? turnId,
    TraceLogger? trace,
    int maxRounds = 5,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  });

  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  });

  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  });
}
