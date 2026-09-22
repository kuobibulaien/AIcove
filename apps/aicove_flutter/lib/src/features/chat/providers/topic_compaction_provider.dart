import '../domain/runtime_context_port.dart';
import '../data/sqlite_runtime_context_store.dart';
import '../../memory/application/compaction_memory_service.dart';
import '../../memory/data/sqlite_compaction_memory_queue.dart';
import '../../memory/domain/compaction_memory.dart';
import '../domain/automatic_context_port.dart';
import '../application/automatic_context_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/database/converters/database_converters.dart';
import '../../background_agent/background_agent_service.dart';
import '../../memory/providers/contact_memory_provider.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../settings/app_settings.dart';
import '../chat_providers.dart';
import '../conversation_providers.dart';
import '../services/chat_history_store.dart';
import '../application/topic_compaction_service.dart';
import '../data/sqlite_topic_handoff_store.dart';
import '../data/background_topic_summary_adapter.dart';
import '../domain/topic_compaction_port.dart';

final topicHandoffStoreProvider = Provider<TopicHandoffStorePort>(
  (ref) => SqliteTopicHandoffStore(
    ref.read(databaseProvider),
    (owner) => ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
  ),
);

final topicSummaryPortProvider = FutureProvider<TopicSummaryPort>(
  (ref) => _buildSummary(ref, automatic: false),
);
final automaticSummaryPortProvider = FutureProvider<TopicSummaryPort>(
  (ref) => _buildSummary(ref, automatic: true),
);

Future<TopicSummaryPort> _buildSummary(
  Ref ref, {
  required bool automatic,
}) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final config = ref.watch(memoryPluginConfigProvider);
  // 复用已配置的总结模型；未配置时使用当前默认聊天模型，不需要 Embedding。
  final configuredName = config.summarizeModelName?.trim() ?? '';
  final configuredProviderId = config.summarizeProviderId?.trim() ?? '';
  final model = configuredName.isNotEmpty
      ? (configuredProviderId.isNotEmpty
            ? settings.buildModelRef(configuredProviderId, configuredName)
            : configuredName)
      : (settings.defaultChatModels.isNotEmpty
            ? settings.defaultChatModels.first
            : settings.defaultModelName);
  return BackgroundTopicSummaryAdapter(
    ref.read(backgroundAgentServiceProvider),
    definition: automatic ? automaticContextSummaryAgent : topicSummaryAgent,
    modelRef: model,
    contextTokens: settings.getMaxContextTokens(model),
    requestTimeout: Duration(
      seconds: settings.callFlowSettings.modelTimeoutSeconds,
    ),
  );
}

final compactionMemoryProvider = Provider<CompactionMemoryPort>(
  (ref) => CompactionMemoryService(
    memory: ref.read(contactMemoryPortProvider),
    queue: SqliteCompactionMemoryQueue(
      ref.read(databaseProvider),
      (owner) => ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    ),
    allowed: (owner) async {
      if (!ref.read(memoryPluginConfigProvider).enabled) return false;
      final row = await ref.read(conversationRepositoryProvider).getById(owner);
      return row != null &&
          row.deletedAt == null &&
          ConversationConverter.fromDb(row).allowsPlugin('memory');
    },
  ),
);

final topicCompactionProvider = Provider<TopicCompactionPort>((ref) {
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
    final plugin = ref.read(pluginManagerProvider).getPlugin('memory');
    if (plugin is MemoryPlugin) plugin.clearConversationCache(owner);
  }

  return TopicCompactionService(
    compactionMemory: ref.read(compactionMemoryProvider),
    store: ref.read(topicHandoffStoreProvider),
    summaryFactory: () => ref.read(topicSummaryPortProvider.future),
    memory: ref.read(contactMemoryPortProvider),
    memoryAllowed: (owner) async {
      if (!ref.read(memoryPluginConfigProvider).enabled) return false;
      final row = await ref.read(conversationRepositoryProvider).getById(owner);
      return row != null &&
          row.deletedAt == null &&
          ConversationConverter.fromDb(row).allowsPlugin('memory');
    },
    readBoundary: (owner) async =>
        (await ref.read(conversationRepositoryProvider).getById(owner))
            ?.contextStartMessageId,
    publishBoundary: publish,
    ensureIdle: (owner) {
      if (ref.read(conversationSendingProvider(owner))) {
        throw const TopicCompactionException('请等当前回复结束后再压缩。');
      }
    },
  );
});

final automaticContextProvider = Provider<AutomaticContextPort>(
  (ref) => AutomaticContextService(
    memory: ref.read(compactionMemoryProvider),
    store: SqliteTopicHandoffStore(
      ref.read(databaseProvider),
      (owner) => ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    ),
    summaryFactory: () => ref.read(automaticSummaryPortProvider.future),
  ),
);

final runtimeContextStoreProvider = Provider<RuntimeContextStorePort>(
  (ref) => SqliteRuntimeContextStore(
    ref.read(databaseProvider),
    (owner) => ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
  ),
);
