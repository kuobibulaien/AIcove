library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/chat_ports.dart';
import 'application/chat_send_use_case.dart';
import 'infrastructure/chat_port_adapters.dart';
import 'services/chat_history_store.dart';
import 'services/chat_send_service.dart';

final chatHistoryPortProvider = Provider<ChatHistoryPort>((ref) {
  final historyStore = ref.watch(chatHistoryStoreProvider);
  return ChatHistoryStoreAdapter(historyStore);
});

final chatSendPortProvider = Provider<ChatSendPort>((ref) {
  final sendService = ref.watch(chatSendServiceProvider);
  return ChatSendServiceAdapter(sendService);
});

final chatSendUseCaseProvider = Provider<ChatSendUseCase>((ref) {
  final sendPort = ref.watch(chatSendPortProvider);
  return ChatSendUseCase(sendPort);
});
