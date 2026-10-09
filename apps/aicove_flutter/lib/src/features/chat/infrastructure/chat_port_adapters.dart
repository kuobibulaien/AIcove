library;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart' show TraceContext;
import '../../settings/app_settings.dart';
import '../application/chat_ports.dart';
import '../application/chat_edit.dart';
import '../domain/chat_context_preview.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../services/chat_history_store.dart';
import '../services/chat_send_service.dart';
import '../services/chat_types.dart'
    show ApiCallResult, ApiConfig, AssistantMessageBuildResult;

class ChatContextPreviewAdapter implements ChatContextPreviewPort {
  const ChatContextPreviewAdapter(this._sendService);

  final ChatSendService _sendService;

  @override
  Future<ChatContextPreview> preview(Conversation conversation) =>
      _sendService.previewContext(conversation);
}

class ChatHistoryStoreAdapter implements ChatHistoryPort, ChatEditPort {
  const ChatHistoryStoreAdapter(this._historyStore);

  final ChatHistoryStore _historyStore;

  @override
  Future<ChatEditDraft> prepareEdit(String conversationId, String messageId) =>
      _historyStore.prepareEdit(conversationId, messageId);

  @override
  Future<void> commitEdit(ChatEditDraft draft, Message replacement) =>
      _historyStore.commitEdit(draft, replacement);

  @override
  Future<List<Message>> loadRawMessages(String conversationId) {
    return _historyStore.loadAllRawMessages(conversationId);
  }

  @override
  Future<void> recoverInterruptedUserMessages(
    String conversationId, {
    required bool Function(String messageId) isActiveSend,
  }) =>
      _historyStore.recoverInterruptedUserMessages(
        conversationId,
        isActiveSend: isActiveSend,
      );

  @override
  Future<void> markMessageStatus({
    required String conversationId,
    required String messageId,
    required String status,
  }) {
    return _historyStore.markMessageStatus(
      conversationId: conversationId,
      messageId: messageId,
      status: status,
    );
  }

  @override
  Future<void> appendAssistantRawMessage({
    required String conversationId,
    required String userMessageId,
    required Message rawMessage,
    required List<Message> projectedMessages,
    required String lastMessagePreview,
    bool updateShortWindow = true,
  }) {
    return _historyStore.appendAssistantRawMessage(
      conversationId: conversationId,
      userMessageId: userMessageId,
      rawMessage: rawMessage,
      projectedMessages: projectedMessages,
      lastMessagePreview: lastMessagePreview,
      updateShortWindow: updateShortWindow,
    );
  }

  @override
  Future<void> softDeleteMessages(
    String conversationId,
    List<String> messageIds, {
    bool clearContextStartIfDeleted = false,
  }) {
    return _historyStore.softDeleteMessages(
      conversationId,
      messageIds,
      clearContextStartIfDeleted: clearContextStartIfDeleted,
    );
  }

  @override
  Future<void> truncateFromMessage({
    required String conversationId,
    required String fromMessageId,
  }) {
    return _historyStore.truncateFromMessage(
      conversationId: conversationId,
      fromMessageId: fromMessageId,
    );
  }

  @override
  Future<void> truncateAfterMessage({
    required String conversationId,
    required String anchorMessageId,
  }) {
    return _historyStore.truncateAfterMessage(
      conversationId: conversationId,
      anchorMessageId: anchorMessageId,
    );
  }
}

class ChatSendServiceAdapter implements ChatSendPort {
  const ChatSendServiceAdapter(this._sendService);

  final ChatSendService _sendService;

  @override
  Message createUserMessage({
    required String? text,
    required String? imagePath,
  }) {
    return _sendService.createUserMessage(
      text: text,
      imagePath: imagePath,
    );
  }

  @override
  Future<Message> createUserFileMessage({
    required String filePath,
    String? text,
  }) {
    return _sendService.createUserFileMessage(
      filePath: filePath,
      text: text,
    );
  }

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) {
    return _sendService.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
  }

  @override
  Future<List<Message>> loadConversationMessagesFromStore({
    required Conversation conv,
    Message? ensureTailMessage,
  }) {
    return _sendService.loadConversationMessagesFromStore(
      conv: conv,
      ensureTailMessage: ensureTailMessage,
    );
  }

  @override
  Future<List<Message>> prepareHistoryFromStore({
    required Conversation conv,
    required Message userMsg,
  }) {
    return _sendService.prepareHistoryFromStore(
      conv: conv,
      userMsg: userMsg,
    );
  }

  @override
  List<String> buildImageSendModelRefs(AppSettings settings) {
    return _sendService.buildImageSendModelRefs(settings);
  }

  @override
  Future<ApiConfig> prepareApiConfig({
    required Conversation conv,
    required List<Message> history,
    required String? userText,
    TraceLogger? trace,
    String? overrideModel,
    String? conversationId,
    TraceContext? traceContext,
  }) {
    return _sendService.prepareApiConfig(
      conv: conv,
      history: history,
      userText: userText,
      trace: trace,
      overrideModel: overrideModel,
      conversationId: conversationId,
      traceContext: traceContext,
    );
  }

  @override
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
  }) {
    return _sendService.executeApiCall(
      config: config,
      sessionId: sessionId,
      userText: userText,
      turnId: turnId,
      trace: trace,
      maxRounds: maxRounds,
      onToolExecuting: onToolExecuting,
      enableStreaming: enableStreaming,
      onStreamTextDelta: onStreamTextDelta,
      onStreamTextReset: onStreamTextReset,
      onStreamToolCallObserved: onStreamToolCallObserved,
      onStreamingFallback: onStreamingFallback,
    );
  }

  @override
  AssistantMessageBuildResult buildAssistantMessages({
    required ApiCallResult apiResult,
    required AppSettings settings,
  }) {
    return _sendService.buildAssistantMessages(
      apiResult: apiResult,
      settings: settings,
    );
  }

  @override
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) {
    return _sendService.markUserMessageFailed(
      convId: convId,
      userMsgId: userMsgId,
    );
  }
}
