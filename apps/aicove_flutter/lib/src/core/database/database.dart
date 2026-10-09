/// (注释已丢失)
///
/// 运行代码生成: flutter pub run build_runner build
library;

import 'dart:io';
import '../sync/cloud_tracking.dart';
import '../sync/lan_tracking.dart';
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
  TextColumn get chatBackgroundImage =>
      text().nullable()(); // per-conversation chat background
  RealColumn get chatBackgroundMaskOpacity =>
      real().nullable()(); // 0.0 - 1.0, null uses default
  RealColumn get chatBackgroundBlurSigma =>
      real().nullable()(); // 0.0 - 30.0, null uses default (0)
  TextColumn get blurredBackground =>
      text().nullable()(); // poster blurred background (base64)
  TextColumn get selfAddress => text().nullable()();
  TextColumn get addressUser => text().nullable()();
  TextColumn get voiceFile => text().nullable()();
  TextColumn get personaPrompt => text().withDefault(const Constant(''))();

  // (注释已丢失)
  TextColumn get defaultProvider => text().nullable()();
  TextColumn get sessionProvider => text().nullable()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  // 移入隐私空间：只从联系人列表隐藏，随同步走（ADR0070）
  BoolColumn get isHidden => boolean().withDefault(const Constant(false))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  BoolColumn get isMuted => boolean().withDefault(const Constant(false))();
  BoolColumn get notificationSound =>
      boolean().withDefault(const Constant(true))();
  TextColumn get enabledPlugins =>
      text().nullable()(); // JSON array of plugin IDs
  TextColumn get recipeId =>
      text().nullable()(); // SillyTavern preset recipe ID
  // 会话级思考档位：JSON 对象 {modelRef: ThinkingLevel.name}
  TextColumn get thinkingLevels => text().nullable()();
  // 会话级聊天样式覆盖：'bubble' | 'document'，null 跟随全局（ADR0047）
  TextColumn get chatDisplayStyle => text().nullable()();

  // 会话摘要缓存
  TextColumn get lastMessage => text().nullable()();
  IntColumn get lastMessageTime => integer().nullable()(); // unix ms
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  // 分支字段
  TextColumn get parentConversationId => text().nullable()();
  TextColumn get forkFromMessageId => text().nullable()();

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // 上下文截断：新话题起始消息ID，此ID之后的消息才纳入AI上下文
  TextColumn get contextStartMessageId => text().nullable()();

  // (注释已丢失)
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // (注释已丢失)
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// (注释已丢失)
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get status => text()
      .withDefault(const Constant('sent'))(); // 'sending' | 'sent' | 'failed'
  BoolColumn get summarized =>
      boolean().withDefault(const Constant(false))(); // 是否已被记忆总结
  IntColumn get summarizedAt => integer().nullable()(); // (注释已丢失)

  // (注释已丢失)
  TextColumn get replacedBy => text().nullable()();
  TextColumn get sourceMessageId => text().nullable()();
  TextColumn get rawPayload => text().nullable()();

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // (注释已丢失)
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // (注释已丢失)
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class MessageProjectionMappings extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get rawMessageId => text().references(Messages, #id)();
  TextColumn get projectedMessageId => text()();
  TextColumn get projectionKind =>
      text().withDefault(const Constant('message'))();
  IntColumn get segmentIndex => integer().withDefault(const Constant(0))();
  TextColumn get projectionVersion => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {rawMessageId, projectedMessageId},
      ];
}

/// (注释已丢失)
class MessageBlocks extends Table {
  TextColumn get id => text()();
  TextColumn get messageId => text().references(Messages, #id)();
  TextColumn get sourceBlockId => text().nullable()();
  TextColumn get type =>
      text()(); // 'mainText' | 'image' | 'audio' | 'emoji' | 'tool' | 'thinking'
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
  TextColumn get capabilities =>
      text().withDefault(const Constant('[]'))(); // JSON array
  TextColumn get customConfig =>
      text().withDefault(const Constant('{}'))(); // JSON object
  TextColumn get modelType => text().nullable()();
  TextColumn get visibleModels => text().withDefault(const Constant('[]'))();
  TextColumn get hiddenModels => text().withDefault(const Constant('[]'))();
  TextColumn get apiKeys =>
      text().withDefault(const Constant('[]'))(); // (注释已丢失)

  // 冲突字段
  TextColumn get conflictOf => text().nullable()();

  // (注释已丢失)
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // (注释已丢失)
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// (注释已丢失)
class SyncScopes extends Table {
  TextColumn get enabledScopes => text()
      .withDefault(const Constant('["chat.history", "characters.cards"]'))();
  IntColumn get updatedAt => integer()();

  // (注释已丢失)
  IntColumn get id => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {id};
}

/// (注释已丢失)
class SyncCursors extends Table {
  TextColumn get deviceId => text()();
  IntColumn get conversationsCursor =>
      integer().withDefault(const Constant(0))();
  IntColumn get messagesCursor => integer().withDefault(const Constant(0))();
  IntColumn get providersCursor => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {deviceId};
}

/// (注释已丢失)
class PendingOperations extends Table {
  TextColumn get opId => text()();
  TextColumn get opType => text()();
  TextColumn get opData => text()(); // JSON
  IntColumn get createdAt => integer()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {opId};
}

@DriftDatabase(tables: [
  Conversations,
  Messages,
  MessageProjectionMappings,
  MessageBlocks,
  Providers,
  SyncScopes,
  SyncCursors,
  PendingOperations,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 21;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await _ensureAutoReplyClaimTable();
        await _ensureContextMemoryTables();
        await _ensureMessageStateTable();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // v1 -> v2 的旧记忆表已随 v18 退役（ADR0038），不再创建。
        // (注释已丢失)
        if (from < 3) {
          await customStatement(
              'ALTER TABLE conversations ADD COLUMN blurred_background TEXT');
        }
        // (注释已丢失)
        if (from < 4) {
          await customStatement(
              'ALTER TABLE conversations ADD COLUMN enabled_plugins TEXT');
        }
        // (注释已丢失)
        if (from < 6) {
          await _safeAddColumn(
              'messages', 'summarized INTEGER NOT NULL DEFAULT 0');
          await _safeAddColumn('messages', 'summarized_at INTEGER');
        }
        // v6 -> v7: add chatBackgroundImage column
        if (from < 7) {
          await _safeAddColumn('conversations', 'chat_background_image TEXT');
        }
        // v7 -> v8: add chatBackgroundMaskOpacity column
        if (from < 8) {
          await _safeAddColumn(
              'conversations', 'chat_background_mask_opacity REAL');
        }
        // v8 -> v9: add chatBackgroundBlurSigma column
        if (from < 9) {
          await _safeAddColumn(
              'conversations', 'chat_background_blur_sigma REAL');
        }
        // v9 -> v10: add contextStartMessageId column
        if (from < 10) {
          await _safeAddColumn(
              'conversations', 'context_start_message_id TEXT');
        }
        // v10 -> v11: add import source id columns
        if (from < 11) {
          await _safeAddColumn('messages', 'source_message_id TEXT');
          await _safeAddColumn('message_blocks', 'source_block_id TEXT');
        }
        // v11 -> v12: add raw payload and raw->frontend projection mapping
        if (from < 12) {
          await _safeAddColumn('messages', 'raw_payload TEXT');
          await m.createTable(messageProjectionMappings);
        }
        // v12 -> v13: add recipeId column
        if (from < 13) {
          await _safeAddColumn('conversations', 'recipe_id TEXT');
        }
        // v13 -> v14: 主动回复触发器执行权认领表（前台/后台互斥）
        if (from < 14) {
          await _ensureAutoReplyClaimTable();
        }
        // v14 -> v15: 会话级思考档位
        if (from < 15) {
          await _safeAddColumn('conversations', 'thinking_levels TEXT');
        }
        // v17 -> v18: 记忆与上下文重构（ADR0038）。只建新表；旧记忆表由
        // LegacyMemoryRetirement 在启动后先备份再删除，这里不直接 DROP。
        if (from < 18) {
          await _ensureContextMemoryTables();
        }
        // v18 -> v19: 会话级聊天样式覆盖（ADR0047）
        if (from < 19) {
          await _safeAddColumn('conversations', 'chat_display_style TEXT');
        }
        // v19 -> v20: 隐私空间隐藏标记（ADR0070）
        if (from < 20) {
          await _safeAddColumn('conversations',
              'is_hidden INTEGER NOT NULL DEFAULT 0 CHECK (is_hidden IN (0, 1))');
        }
        // v20 -> v21: 会话状态快照（MVU 变量等，ADR0071），只存本机不同步
        if (from < 21) {
          await _ensureMessageStateTable();
        }
      },
      // 只补物理访问索引，不改变表/记录格式或user_version。
      // 已有v16也能获得索引，且回退到此前v16应用无需降级数据库。
      beforeOpen: (_) => _ensureChatEntryIndexes(),
    );
  }

  Future<void> _ensureChatEntryIndexes() async {
    for (var attempt = 0;; attempt++) {
      try {
        await transaction(() async {
          await installCloudTracking(this);
          await installLanTracking(this);
          // 默认ASC与隐含rowid同向；倒序扫描即可匹配created_at DESC,
          // rowid DESC。显式把时间列改成DESC反而会为同时间戳二次排序。
          await customStatement('''
CREATE INDEX IF NOT EXISTS messages_active_conversation_time
ON messages(conversation_id, created_at)
WHERE deleted_at IS NULL AND replaced_by IS NULL
''');
          await customStatement('''
CREATE INDEX IF NOT EXISTS message_blocks_active_message_order
ON message_blocks(message_id, sort_order)
WHERE deleted_at IS NULL
''');
        });
        return;
      } on SqliteException catch (error) {
        // 前台/后台连接可同时首次打开。先回滚释放锁，再有界异步重试；
        // 不改连接全局busy_timeout，不吞磁盘/语法等非锁错误。
        if ((error.resultCode != 5 && error.resultCode != 6) || attempt >= 6) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
      }
    }
  }

  /// 上下文摘要与长期记忆（ADR0038）。由专用 Adapter 以参数化 SQL 访问，
  /// 不走 Drift 表定义；每张表一条独立语句，均可重复执行。
  Future<void> _ensureContextMemoryTables() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS context_summaries (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  boundary_id TEXT NOT NULL,
  topic_boundary TEXT,
  summary TEXT NOT NULL,
  source_ids TEXT NOT NULL,
  source_digest TEXT NOT NULL,
  created_at INTEGER NOT NULL
)''');
    await customStatement('''
CREATE INDEX IF NOT EXISTS context_summaries_owner_kind
ON context_summaries(owner_id, kind, boundary_id, created_at)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS memory_items (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  layer TEXT NOT NULL,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  source_ids TEXT NOT NULL DEFAULT '[]',
  locked INTEGER NOT NULL DEFAULT 0,
  embedding BLOB,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''');
    await customStatement('''
CREATE INDEX IF NOT EXISTS memory_items_owner_layer
ON memory_items(owner_id, layer, updated_at)''');
    await customStatement('''
CREATE VIRTUAL TABLE IF NOT EXISTS memory_items_fts
USING fts5(item_id UNINDEXED, owner_id UNINDEXED, tokens)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS memory_progress (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  until_at INTEGER,
  until_id TEXT,
  rebuild_until_id TEXT,
  generation INTEGER NOT NULL DEFAULT 0,
  paused INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  updated_at INTEGER NOT NULL
)''');
  }

  /// 会话状态快照（ADR0071）：冻结基线（anchor_id = '__init__'）与按消息的
  /// 可重算缓存。由 SqliteConversationStateStore 以参数化 SQL 访问；不同步。
  Future<void> _ensureMessageStateTable() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS message_states (
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  anchor_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  prev_anchor_id TEXT,
  raw_hash TEXT NOT NULL,
  engine_version INTEGER NOT NULL,
  status TEXT NOT NULL,
  data_json TEXT,
  diagnostics_json TEXT NOT NULL DEFAULT '[]',
  sources_json TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (conversation_id, anchor_id, kind)
)''');
    await customStatement('''
CREATE INDEX IF NOT EXISTS message_states_conversation_kind
ON message_states(conversation_id, kind)''');
  }

  /// 主动回复触发器执行权认领表：前台轮询与后台 WorkManager 发送前
  /// 必须先 INSERT OR IGNORE 认领，认领失败即另一方已执行。
  /// 不走 drift 表定义（仅 raw SQL 访问），避免为单一互斥表引入 codegen。
  Future<void> _ensureAutoReplyClaimTable() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS auto_reply_trigger_claims (
  trigger_id TEXT NOT NULL PRIMARY KEY,
  claimed_by TEXT NOT NULL,
  claimed_at INTEGER NOT NULL
)
''');
  }

  Future<void> _safeAddColumn(String table, String columnDef) async {
    try {
      await customStatement('ALTER TABLE $table ADD COLUMN $columnDef');
    } catch (_) {
      // (注释已丢失)
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'aicove.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // Keep foreign key constraints on for all platforms.
        db.execute('PRAGMA foreign_keys = ON');
        try {
          db.execute('PRAGMA journal_mode = WAL');
        } catch (e) {
          // Some Windows environments can transiently fail switching to WAL.
          // Fall back so database open doesn't crash the whole app.
          try {
            db.execute('PRAGMA journal_mode = DELETE');
          } catch (_) {}
          stderr.writeln(
            '[Database] Failed to enable WAL, fallback to DELETE: $e',
          );
        }
      },
    );
  });
}
