library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/chat_ports.dart';
import 'application/chat_edit.dart';
import 'application/chat_send_use_case.dart';
import 'application/standard_chat_agent.dart';
import '../agent_context/domain/agent_runtime_contracts.dart';
import 'infrastructure/chat_port_adapters.dart';
import 'services/chat_history_store.dart';
import 'services/chat_send_service.dart';

final chatHistoryPortProvider = Provider<ChatHistoryPort>((ref) {
  final historyStore = ref.watch(chatHistoryStoreProvider);
  return ChatHistoryStoreAdapter(historyStore);
});

final chatEditPortProvider = Provider<ChatEditPort>(
    (ref) => ChatHistoryStoreAdapter(ref.watch(chatHistoryStoreProvider)));

final chatEditSeedProvider =
    StateProvider.family<ChatEditSeed?, String>((ref, owner) => null);

final chatSendPortProvider = Provider<ChatSendPort>((ref) {
  final sendService = ref.watch(chatSendServiceProvider);
  return ChatSendServiceAdapter(sendService);
});

final chatContextPreviewPortProvider = Provider<ChatContextPreviewPort>(
    (ref) => ChatContextPreviewAdapter(ref.watch(chatSendServiceProvider)));

final chatSendUseCaseProvider = Provider<ChatSendUseCase>((ref) {
  final sendPort = ref.watch(chatSendPortProvider);
  return ChatSendUseCase(sendPort);
});

final standardChatAgentRuntimeProvider =
    Provider<StandardChatAgentRuntime>((ref) {
  final sendUseCase = ref.watch(chatSendUseCaseProvider);
  return StandardChatAgentRuntime(sendUseCase);
});

final standardChatAgentSchedulerProvider = Provider<
    AgentScheduler<StandardChatAgentRunRequest,
        StandardChatAgentRunResult>>((ref) {
  final runtime = ref.watch(standardChatAgentRuntimeProvider);
  return DirectAgentScheduler<StandardChatAgentRunRequest,
      StandardChatAgentRunResult>(runtime);
});

final standardChatAgentProvider = Provider<StandardChatAgent>((ref) {
  final scheduler = ref.watch(standardChatAgentSchedulerProvider);
  return StandardChatAgent(scheduler);
});
