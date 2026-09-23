import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/database/database_provider.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/chat_providers.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/services/chat_history_store.dart';
import '../../memory/providers/memory_providers.dart';
import '../../settings/app_settings.dart';
import '../application/context_manager.dart';
import '../data/background_context_summarizer.dart';
import '../data/sqlite_context_summary_store.dart';
import '../domain/context_summary.dart';

/// 旧「长期记忆」插件里配置过的总结模型；新设置为空时沿用它。
Future<String> _legacySummarizeModel(AppSettings settings) async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString(
      'aicove.plugins.memory.config',
    );
    if (raw == null || raw.isEmpty) return '';
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final name = (data['summarizeModelName'] as String?)?.trim() ?? '';
    final provider = (data['summarizeProviderId'] as String?)?.trim() ?? '';
    if (name.isEmpty) return '';
    return provider.isEmpty ? name : settings.buildModelRef(provider, name);
  } catch (_) {
    return '';
  }
}

/// 压缩模型：设置值 → 旧总结模型 → 默认聊天模型。
Future<String> resolveCompactionModel(AppSettings settings) async {
  final configured = settings.compactionModel.trim();
  if (configured.isNotEmpty) return configured;
  final legacy = await _legacySummarizeModel(settings);
  if (legacy.isNotEmpty) return legacy;
  return settings.defaultChatModels.isNotEmpty
      ? settings.defaultChatModels.first
      : settings.defaultModelName;
}

/// 记忆模型：设置值 → 压缩模型。
Future<String> resolveMemoryModel(AppSettings settings) async {
  final configured = settings.memoryModel.trim();
  return configured.isNotEmpty
      ? configured
      : await resolveCompactionModel(settings);
}

final contextSummaryStoreProvider = Provider<ContextSummaryStorePort>(
  (ref) => SqliteContextSummaryStore(
    ref.read(databaseProvider),
    (owner) => ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
  ),
);

final contextSummarizerProvider = FutureProvider<ContextSummarizerPort>((
  ref,
) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final model = await resolveCompactionModel(settings);
  return BackgroundContextSummarizer(
    ref.read(backgroundAgentServiceProvider),
    modelRef: model,
    contextTokens: settings.getMaxContextTokens(model),
    requestTimeout: Duration(
      seconds: settings.callFlowSettings.modelTimeoutSeconds,
    ),
  );
});

final contextManagerProvider = Provider<ContextManager>((ref) {
  Future<void> publish(String owner) async {
    final row = await ref.read(conversationRepositoryProvider).getById(owner);
    if (row == null) return;
    await ref
        .read(conversationsProvider.notifier)
        .updateOne(
          owner,
          (current) => current.copyWith(
            contextStartMessageId: row.contextStartMessageId,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
          ),
          persist: false,
        );
  }

  return ContextManager(
    store: ref.read(contextSummaryStoreProvider),
    loadMessages: (owner) =>
        ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    readBoundary: (owner) async =>
        (await ref.read(conversationRepositoryProvider).getById(owner))
            ?.contextStartMessageId,
    summarizerFactory: () => ref.read(contextSummarizerProvider.future),
    publishBoundary: publish,
    ensureIdle: (owner) {
      if (ref.read(conversationSendingProvider(owner))) {
        throw const ContextCompactionException('请等当前回复结束后再压缩。');
      }
    },
    onCompacted: (owner) => ref.read(memoryKeeperProvider).schedule(owner),
  );
});

/// 界面使用的手动压缩端口。
final manualCompactionProvider = Provider<ManualCompactionPort>(
  (ref) => ref.watch(contextManagerProvider),
);

/// 发送链路使用的上下文端口。
final conversationContextProvider = Provider<ConversationContextPort>(
  (ref) => ref.watch(contextManagerProvider),
);
