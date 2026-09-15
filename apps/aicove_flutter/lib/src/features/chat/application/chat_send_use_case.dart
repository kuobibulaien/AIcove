library;

import '../../../core/app_logger.dart' show TraceLogger;
import '../../observability/trace_models.dart' show TraceContext;
import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import '../services/chat_types.dart'
    show ApiCallResult, ApiConfig, AssistantMessageBuildResult;
import 'chat_ports.dart';
import 'chat_turn_command.dart';

typedef ChatFailoverExecutor = Future<(ApiCallResult, AppSettings)> Function({
  required List<String> modelsToTry,
  required Future<ApiConfig> Function(String model) buildConfig,
  required Future<ApiCallResult> Function(ApiConfig config) execute,
  required AppSettings settings,
});

typedef ChatResultDelivery = Future<void> Function({
  required AppSettings settings,
  required ApiCallResult apiResult,
  required AssistantMessageBuildResult buildResult,
});

class ChatPreparedTurn {
  const ChatPreparedTurn({
    required this.requestConversation,
    required this.history,
    required this.sessionId,
    this.modelsToTry,
    this.transformApiResult,
  });

  final Conversation requestConversation;
  final List<Message> history;
  final String sessionId;
  final List<String>? modelsToTry;
  final ApiCallResult Function(ApiCallResult rawResult)? transformApiResult;
}

class ChatSendTurnResult {
  const ChatSendTurnResult({
    required this.apiResult,
    required this.buildResult,
    required this.settings,
  });

  final ApiCallResult apiResult;
  final AssistantMessageBuildResult buildResult;
  final AppSettings settings;
}

class ChatTurnExecutionOptions {
  const ChatTurnExecutionOptions({
    required this.loadSettings,
    this.prepareTurn,
    this.resolveModelsToTry,
    required this.executeWithFailover,
    this.prepareStreaming,
    required this.onToolExecuting,
    this.onProcessingResponse,
    required this.deliverResult,
    required this.isCurrent,
    this.onStreamTextDelta,
    this.onStreamTextReset,
    this.onStreamToolCallObserved,
    this.onStreamingFallback,
  });

  final Future<AppSettings> Function() loadSettings;
  final Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn;
  final List<String> Function(AppSettings settings)? resolveModelsToTry;
  final ChatFailoverExecutor executeWithFailover;
  final Future<void> Function(AppSettings settings)? prepareStreaming;
  final void Function(String toolName) onToolExecuting;
  final void Function()? onProcessingResponse;
  final ChatResultDelivery deliverResult;
  final bool Function() isCurrent;
  final void Function(String delta)? onStreamTextDelta;
  final void Function()? onStreamTextReset;
  final void Function()? onStreamToolCallObserved;
  final void Function()? onStreamingFallback;
}

class ChatSendUseCase {
  const ChatSendUseCase(this._sendPort);

  final ChatSendPort _sendPort;

  List<String> _normalizeModelsToTry({
    required AppSettings settings,
    List<String>? candidates,
  }) {
    final normalized = <String>[];

    void addCandidate(String? value) {
      final model = value?.trim();
      if (model == null || model.isEmpty || normalized.contains(model)) {
        return;
      }
      normalized.add(model);
    }

    for (final model in candidates ?? const <String>[]) {
      addCandidate(model);
    }

    if (normalized.isNotEmpty) {
      return normalized;
    }

    for (final model in settings.defaultChatModels) {
      addCandidate(model);
    }
    addCandidate(settings.defaultModelName);
    return normalized;
  }

  Future<ChatSendTurnResult?> executeTurn({
    required ChatTurnCommand command,
    required ChatTurnExecutionOptions options,
  }) async {
    final settings = await options.loadSettings();
    if (!options.isCurrent()) return null;

    final preparedTurn = options.prepareTurn != null
        ? await options.prepareTurn!(settings)
        : ChatPreparedTurn(
            requestConversation: command.conversation,
            history: await _sendPort.prepareHistoryFromStore(
              conv: command.conversation,
              userMsg: command.userMessage,
            ),
            sessionId: command.sessionId,
          );
    if (!options.isCurrent()) return null;

    if (command.isStreaming) {
      final prepareStreaming = options.prepareStreaming;
      if (prepareStreaming == null) {
        throw ArgumentError(
          'prepareStreaming is required for streaming commands',
        );
      }
      await prepareStreaming(settings);
      if (!options.isCurrent()) return null;
    }

    final modelsToTry = _normalizeModelsToTry(
      settings: settings,
      candidates: preparedTurn.modelsToTry ??
          options.resolveModelsToTry?.call(settings),
    );

    return _executeTurn(
      conversation: preparedTurn.requestConversation,
      userMessage: command.userMessage,
      apiText: command.apiText,
      traceContext: command.traceContext,
      trace: command.trace,
      settings: settings,
      history: preparedTurn.history,
      modelsToTry: modelsToTry,
      transformApiResult: preparedTurn.transformApiResult,
      executeWithFailover: options.executeWithFailover,
      execute: (config) => _sendPort.executeApiCall(
        config: config,
        sessionId: preparedTurn.sessionId,
        userText: command.apiText,
        turnId: command.userMessage.id,
        trace: command.trace,
        onToolExecuting: options.onToolExecuting,
        enableStreaming: command.isStreaming,
        onStreamTextDelta: options.onStreamTextDelta,
        onStreamTextReset: options.onStreamTextReset,
        onStreamToolCallObserved: options.onStreamToolCallObserved,
        onStreamingFallback: options.onStreamingFallback,
      ),
      deliverResult: options.deliverResult,
      isCurrent: options.isCurrent,
    );
  }

  Future<ChatSendTurnResult?> executeNonStreamingTurn({
    required Conversation conversation,
    required Message userMessage,
    required String sessionId,
    required String apiText,
    required TraceContext? traceContext,
    required Future<AppSettings> Function() loadSettings,
    Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn,
    required List<String> Function(AppSettings settings) resolveModelsToTry,
    required ChatFailoverExecutor executeWithFailover,
    required void Function(String toolName) onToolExecuting,
    void Function()? onProcessingResponse,
    required ChatResultDelivery deliverResult,
    required bool Function() isCurrent,
  }) {
    return executeTurn(
      command: ChatTurnCommand.nonStreaming(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: sessionId,
        apiText: apiText,
        traceContext: traceContext,
      ),
      options: ChatTurnExecutionOptions(
        loadSettings: loadSettings,
        prepareTurn: prepareTurn,
        resolveModelsToTry: resolveModelsToTry,
        executeWithFailover: executeWithFailover,
        onToolExecuting: onToolExecuting,
        onProcessingResponse: onProcessingResponse,
        deliverResult: deliverResult,
        isCurrent: isCurrent,
      ),
    );
  }

  Future<ChatSendTurnResult?> executeStreamingTurn({
    required Conversation conversation,
    required Message userMessage,
    required String sessionId,
    required String apiText,
    required TraceContext? traceContext,
    TraceLogger? trace,
    required Future<AppSettings> Function() loadSettings,
    List<String> Function(AppSettings settings)? resolveModelsToTry,
    Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn,
    required ChatFailoverExecutor executeWithFailover,
    required Future<void> Function(AppSettings settings) prepareStreaming,
    required void Function(String toolName) onToolExecuting,
    void Function()? onProcessingResponse,
    required ChatResultDelivery deliverResult,
    required bool Function() isCurrent,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) {
    return executeTurn(
      command: ChatTurnCommand.streaming(
        conversation: conversation,
        userMessage: userMessage,
        sessionId: sessionId,
        apiText: apiText,
        traceContext: traceContext,
        trace: trace,
      ),
      options: ChatTurnExecutionOptions(
        loadSettings: loadSettings,
        prepareTurn: prepareTurn,
        resolveModelsToTry: resolveModelsToTry,
        executeWithFailover: executeWithFailover,
        prepareStreaming: prepareStreaming,
        onToolExecuting: onToolExecuting,
        onProcessingResponse: onProcessingResponse,
        deliverResult: deliverResult,
        isCurrent: isCurrent,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
      ),
    );
  }

  Future<ChatSendTurnResult?> _executeTurn({
    required Conversation conversation,
    required Message userMessage,
    required String apiText,
    required TraceContext? traceContext,
    TraceLogger? trace,
    required AppSettings settings,
    required List<Message> history,
    required List<String> modelsToTry,
    ApiCallResult Function(ApiCallResult rawResult)? transformApiResult,
    required ChatFailoverExecutor executeWithFailover,
    required Future<ApiCallResult> Function(ApiConfig config) execute,
    required ChatResultDelivery deliverResult,
    required bool Function() isCurrent,
  }) async {
    final (rawApiResult, usedSettings) = await executeWithFailover(
      modelsToTry: modelsToTry,
      buildConfig: (model) => _sendPort.prepareApiConfig(
        conv: conversation,
        history: history,
        userText: apiText,
        trace: trace,
        overrideModel: model,
        conversationId: conversation.id,
        traceContext: traceContext,
      ),
      execute: execute,
      settings: settings,
    );
    if (!isCurrent()) return null;
    final apiResult = transformApiResult?.call(rawApiResult) ?? rawApiResult;

    // 旧的“消息整理中”阶段会在 API 返回后额外切一次前端状态，
    // 但当前多模态链路已经在 deliverResult 内按顺序直接交付，
    // 再切一层 post-processing 状态只会制造闪烁，不再参与运行时流程。
    final buildResult = _sendPort.buildAssistantMessages(
      apiResult: apiResult,
      settings: usedSettings,
    );
    if (!isCurrent()) return null;

    await deliverResult(
      settings: usedSettings,
      apiResult: apiResult,
      buildResult: buildResult,
    );
    if (!isCurrent()) return null;

    return ChatSendTurnResult(
      apiResult: apiResult,
      buildResult: buildResult,
      settings: usedSettings,
    );
  }
}
