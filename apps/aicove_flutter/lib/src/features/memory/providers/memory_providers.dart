import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../background_agent/background_agent_service.dart';
import '../../chat/services/chat_history_store.dart';
import '../../context/providers/context_providers.dart';
import '../../settings/app_settings.dart';
import '../application/memory_keeper_service.dart';
import '../application/memory_retrieval.dart';
import '../data/background_memory_agent_adapter.dart';
import '../data/legacy_memory_retirement.dart';
import '../data/sqlite_memory_store.dart';
import '../domain/memory_ports.dart';

final memoryStoreProvider = Provider<MemoryStorePort>(
  (ref) => SqliteMemoryStore(ref.read(databaseProvider)),
);

/// 窗口外记忆的检索实现。以后接向量检索时只替换这里。
final memoryRetrieverProvider = Provider<MemoryRetriever>(
  (ref) => KeywordMemoryRetriever(ref.read(memoryStoreProvider)),
);

final memoryInjectorProvider = Provider<MemoryInjector>(
  (ref) => MemoryInjector(
    store: ref.read(memoryStoreProvider),
    retriever: ref.read(memoryRetrieverProvider),
  ),
);

final memoryAgentProvider = FutureProvider<MemoryAgentPort>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  final model = await resolveMemoryModel(settings);
  return BackgroundMemoryAgentAdapter(
    ref.read(backgroundAgentServiceProvider),
    store: ref.read(memoryStoreProvider),
    modelRef: model,
    contextTokens: settings.getMaxContextTokens(model),
    requestTimeout: Duration(
      seconds: settings.callFlowSettings.modelTimeoutSeconds * 2,
    ),
  );
});

/// 角色是否启用长期记忆：以角色的插件选择为唯一开关（ADR0035）。
Future<bool> memoryAllowedFor(Ref ref, String ownerId) async {
  final row = await ref.read(conversationRepositoryProvider).getById(ownerId);
  return row != null &&
      row.deletedAt == null &&
      ConversationConverter.fromDb(row).allowsPlugin('memory');
}

final memoryKeeperProvider = Provider<MemoryKeeperService>(
  (ref) => MemoryKeeperService(
    store: ref.read(memoryStoreProvider),
    loadMessages: (owner) =>
        ref.read(chatHistoryStoreProvider).loadAllRawMessages(owner),
    compactedBoundaries: (owner) =>
        ref.read(contextSummaryStoreProvider).compactedBoundaries(owner),
    agentFactory: () => ref.read(memoryAgentProvider.future),
    allowed: (owner) => memoryAllowedFor(ref, owner),
  ),
);

final legacyMemoryRetirementProvider = Provider<LegacyMemoryRetirement>(
  (ref) => LegacyMemoryRetirement(
    ref.read(databaseProvider),
    supportDirectory: getApplicationSupportDirectory,
  ),
);
