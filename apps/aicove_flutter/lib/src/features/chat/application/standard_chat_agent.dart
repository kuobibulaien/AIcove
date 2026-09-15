library;

import '../../agent_context/domain/agent_runtime_contracts.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';
import 'chat_send_use_case.dart';
import 'chat_turn_command.dart';

/// 前台聊天的标准 Agent 标识。
///
/// 第一阶段只把聊天主链路包装成标准 AgentRunRequest，不改变内部发送行为。
/// ChatAgent 是联系人级 Agent，并拥有完整上下文装配权限；后台 Agent
/// 复用同一套槽位，但通过 ContextProfile 收窄为专业化权限。
abstract final class StandardChatAgentIds {
  static String agentIdForContact(String contactId) => 'chat_agent:$contactId';

  static String agentNameForConversation(Conversation conversation) =>
      'ChatAgent:${conversation.displayName}';

  static String contextRecipeIdForContact(String contactId) =>
      'standard_chat_recipe:$contactId';

  static String contextRecipeIdForConversation(Conversation conversation) {
    final boundRecipeId = conversation.recipeId?.trim();
    return boundRecipeId != null && boundRecipeId.isNotEmpty
        ? boundRecipeId
        : contextRecipeIdForContact(conversation.id);
  }

  static AgentDefinition definitionForConversation(Conversation conversation) {
    return AgentDefinition(
      id: agentIdForContact(conversation.id),
      name: agentNameForConversation(conversation),
      objective: conversation.personaPrompt,
      triggerKind: AgentTriggerKind.userMessage,
      agentKind: AgentKind.chat,
      contextRecipeId: contextRecipeIdForConversation(conversation),
      contextProfile: ContextProfile.standardChat,
      outputContract: AgentOutputContract.standardChat,
      deliveryChannel: AgentDeliveryChannelKind.foregroundConversation,
      traceKind: AgentTraceKind.foreground,
      modelRef: conversation.sessionProvider ?? conversation.defaultProvider,
    );
  }
}

/// 前台聊天的一次标准 Agent 运行请求。
class StandardChatAgentRunRequest extends AgentRunRequest {
  final ChatTurnCommand command;
  final ChatTurnExecutionOptions options;

  StandardChatAgentRunRequest({
    required this.command,
    required this.options,
    String? runId,
  }) : super(
          runId: runId ?? 'chat_${command.userMessage.id}',
          agentId:
              StandardChatAgentIds.agentIdForContact(command.conversation.id),
          agentKind: AgentKind.chat,
          triggerKind: AgentTriggerKind.userMessage,
          conversationId: command.conversation.id,
          contactId: command.conversation.id,
          triggerPayload: command,
          inputMessages: <Message>[command.userMessage],
          contextOverrides: <String, Object?>{
            'contextRecipeId':
                StandardChatAgentIds.contextRecipeIdForConversation(
              command.conversation,
            ),
            'contactId': command.conversation.id,
            'conversationId': command.conversation.id,
          },
          deliveryChannel: AgentDeliveryChannelKind.foregroundConversation,
          traceKind: AgentTraceKind.foreground,
          metadata: <String, Object?>{
            'agentName': StandardChatAgentIds.agentNameForConversation(
                command.conversation),
            'contactId': command.conversation.id,
            'contactDisplayName': command.conversation.displayName,
            'contextAssemblyScope': 'full_chat',
            'assemblyPermissions': AgentContextAssemblyPermissions.fullChat
                .map((permission) => permission.id)
                .toList(growable: false),
            'sessionId': command.sessionId,
            'executionMode': command.executionMode.name,
            'streaming': command.isStreaming,
            'apiTextLength': command.apiText.length,
            'delegate': 'ChatSendUseCase',
          },
        );
}

/// 前台聊天 Agent 的运行结果。
class StandardChatAgentRunResult extends AgentRunResult {
  final ChatSendTurnResult? turnResult;

  StandardChatAgentRunResult({
    required StandardChatAgentRunRequest request,
    required this.turnResult,
  }) : super(
          request: request,
          status: turnResult == null
              ? AgentRunStatus.skipped
              : AgentRunStatus.completed,
          metadata: <String, Object?>{
            'delegate': 'ChatSendUseCase',
            'hasTurnResult': turnResult != null,
          },
        );

  StandardChatAgentRunRequest get chatRequest =>
      request as StandardChatAgentRunRequest;
}

/// 标准前台聊天 Agent Runtime。
///
/// 当前仍委托给既有 ChatSendUseCase，保证 UI、流式、工具调用、TTS/图片
/// 插件投递等行为完全沿用旧链路。后续再逐步把上下文组装迁到
/// ContextRuntime。
class StandardChatAgentRuntime
    implements
        AgentRuntime<StandardChatAgentRunRequest, StandardChatAgentRunResult> {
  final ChatSendUseCase _delegate;

  const StandardChatAgentRuntime(this._delegate);

  @override
  Future<StandardChatAgentRunResult> run(
    StandardChatAgentRunRequest request,
  ) async {
    final turnResult = await _delegate.executeTurn(
      command: request.command,
      options: request.options,
    );
    return StandardChatAgentRunResult(
      request: request,
      turnResult: turnResult,
    );
  }
}

/// 前台聊天 Agent 外壳。
///
/// ChatActions 以后只关心“提交一次 ChatAgent 运行”，而不是直接拥有
/// ChatSendUseCase 的特殊入口。
class StandardChatAgent {
  final AgentScheduler<StandardChatAgentRunRequest, StandardChatAgentRunResult>
      _scheduler;

  const StandardChatAgent(this._scheduler);

  Future<ChatSendTurnResult?> executeTurn({
    required ChatTurnCommand command,
    required ChatTurnExecutionOptions options,
  }) async {
    final result = await _scheduler.submit(
      StandardChatAgentRunRequest(
        command: command,
        options: options,
      ),
    );
    return result.turnResult;
  }
}
