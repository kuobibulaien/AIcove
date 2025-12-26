/// Drift 数据库定义（施工手册 4.x 对应的本地表结构）
///
/// 运行代码生成: flutter pub run build_runner build
library;

import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

/// 会话/角色卡表
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get displayName => text()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get characterImage => text().nullable()();
  TextColumn get selfAddress => text().nullable()();
  TextColumn get addressUser => text().nullable()();
  TextColumn get voiceFile => text().nullable()();
  TextColumn get personaPrompt => text().withDefault(const Constant(''))();

  // 单角色设置
  TextColumn get defaultProvider => text().nullable()();
  TextColumn get sessionProvider => text().nullable()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  BoolColumn get isMuted => boolean().withDefault(const Constant(false))();
  BoolColumn get notificationSound => boolean().withDefault(const Constant(true))();

  // 会话摘要缓存
  TextColumn get lastMessage => text().nullable()();
  IntColumn get lastMessageTime => integer().nullable()(); // unix ms
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  // 分支字段
  TextColumn get parentConversationId => text().nullable()();
  TextColumn get forkFromMessageId => text().nullable()();

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // 回收站字段
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 时间戳
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 消息表
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get status => text().withDefault(const Constant('sent'))(); // 'sending' | 'sent' | 'failed'

  // 重生成覆盖字段
  TextColumn get replacedBy => text().nullable()();

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // 回收站字段
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 时间戳
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 多模态内容块表
class MessageBlocks extends Table {
  TextColumn get id => text()();
  TextColumn get messageId => text().references(Messages, #id)();
  TextColumn get type => text()(); // 'mainText' | 'image' | 'audio' | 'emoji' | 'tool' | 'thinking'
  TextColumn get status => text().withDefault(const Constant('success'))();
  TextColumn get data => text()(); // JSON
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 渠道商配置表
class Providers extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get apiBaseUrl => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  TextColumn get capabilities => text().withDefault(const Constant('[]'))(); // JSON array
  TextColumn get customConfig => text().withDefault(const Constant('{}'))(); // JSON object
  TextColumn get modelType => text().nullable()();
  TextColumn get visibleModels => text().withDefault(const Constant('[]'))();
  TextColumn get hiddenModels => text().withDefault(const Constant('[]'))();
  TextColumn get apiKeys => text().withDefault(const Constant('[]'))(); // JSON array（本地明文，云端加密）

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // 回收站字段
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 时间戳
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 同步范围配置表
class SyncScopes extends Table {
  TextColumn get enabledScopes => text().withDefault(const Constant('["chat.history", "characters.cards"]'))();
  IntColumn get updatedAt => integer()();

  // 单行表，用固定 id
  IntColumn get id => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 同步游标表（记录同步位置）
class SyncCursors extends Table {
  TextColumn get deviceId => text()();
  IntColumn get conversationsCursor => integer().withDefault(const Constant(0))();
  IntColumn get messagesCursor => integer().withDefault(const Constant(0))();
  IntColumn get providersCursor => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// 待同步操作队列（离线时暂存）
class PendingOperations extends Table {
  TextColumn get opId => text()();
  TextColumn get opType => text()();
  TextColumn get opData => text()(); // JSON
  IntColumn get createdAt => integer()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {opId};
}

/// 记忆表（有效记忆 + 回收站记忆）
///
/// 本地上限 800 条有效记忆，超额按 importance 淘汰进回收站
/// P=1 为核心记忆，不参与自动淘汰，timeCoef 强制为 1
class Memories extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()(); // 记忆文本（对话摘要/事实）
  TextColumn get embedding => text().nullable()(); // 向量，JSON格式存储

  // AI 打分项（0~1）
  RealColumn get persistenceP => real().withDefault(const Constant(0.5))(); // P 持久性
  RealColumn get emotionE => real().withDefault(const Constant(0.0))(); // E 情绪值
  RealColumn get infoI => real().withDefault(const Constant(0.5))(); // I 信息量
  RealColumn get judgeJ => real().withDefault(const Constant(0.5))(); // J 综合判断

  // 计算后的重要性字段
  RealColumn get infoImportance => real().withDefault(const Constant(0.5))(); // 信息重要性
  RealColumn get timeCoef => real().withDefault(const Constant(1.0))(); // 时间系数 (0.8~1)
  RealColumn get importance => real().withDefault(const Constant(0.5))(); // 最终重要性

  // 系统维护字段
  IntColumn get useCount => integer().withDefault(const Constant(0))(); // 被注入topK的次数
  IntColumn get lastActiveAt => integer().nullable()(); // 最后被注入的时间 (unix ms)

  // 回收站字段
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 同步字段
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get syncState => text().withDefault(const Constant('local'))(); // local/synced/modified

  // 时间戳
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 记忆墓碑表（用于幂等、防重复上传）
class MemoryTombstones extends Table {
  TextColumn get tombstoneId => text()();
  TextColumn get memoryId => text()(); // 对应的记忆 id
  TextColumn get reason => text()(); // evicted / replaced / user_delete / conflict_patch
  TextColumn get payloadHash => text().nullable()(); // 可选，用于幂等与调试

  // 时间字段
  IntColumn get deletedAt => integer()();
  IntColumn get purgeAt => integer()();
  IntColumn get cloudSyncedAt => integer().nullable()(); // 成功上传墓碑到云端的时间

  @override
  Set<Column> get primaryKey => {tombstoneId};
}

@DriftDatabase(tables: [
  Conversations,
  Messages,
  MessageBlocks,
  Providers,
  SyncScopes,
  SyncCursors,
  PendingOperations,
  Memories,
  MemoryTombstones,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // v1 -> v2: 新增 memories 和 memory_tombstones 表
        if (from < 2) {
          await m.createTable(memories);
          await m.createTable(memoryTombstones);
        }
      },
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'mygril.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // 启用外键和 WAL 模式
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA journal_mode = WAL');
      },
    );
  });
}
