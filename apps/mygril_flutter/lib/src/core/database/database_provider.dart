/// 数据库服务提供者
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database.dart' hide Provider;
import 'repositories/repositories.dart';

/// 全局数据库实例
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// 会话 Repository
final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  return ConversationRepository(ref.watch(databaseProvider));
});

/// 消息 Repository
final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository(ref.watch(databaseProvider));
});

/// 消息内容块 Repository
final messageBlockRepositoryProvider = Provider<MessageBlockRepository>((ref) {
  return MessageBlockRepository(ref.watch(databaseProvider));
});

/// 渠道商 Repository
final providerRepositoryProvider = Provider<ProviderRepository>((ref) {
  return ProviderRepository(ref.watch(databaseProvider));
});

/// 记忆 Repository
final memoryRepositoryProvider = Provider<MemoryRepository>((ref) {
  return MemoryRepository(ref.watch(databaseProvider));
});
