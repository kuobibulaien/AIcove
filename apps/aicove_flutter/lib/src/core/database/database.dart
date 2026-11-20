/// (注释已丢失)
///
/// 运行代码生成: flutter pub run build_runner build
library;

import 'dart:io';
import '../sync/cloud_tracking.dart';
import '../sync/lan_tracking.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import '../storage/app_data_directory.dart';

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
  // 壁纸宽窄屏截取（JSON），null 为默认居中
  TextColumn get chatBackgroundFraming => text().nullable()();
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
  // 聊天界面显示偏好（按联系人），null 沿用旧的全局值
  RealColumn get imagePreviewScale => real().nullable()();
  BoolColumn get expandAudioText => boolean().nullable()();
  BoolColumn get hideUserAvatar => boolean().nullable()();
  // 气泡分段（按联系人），null 跟随全局默认
  BoolColumn get chunkEnabled => boolean().nullable()();
  BoolColumn get filterPunctuation => boolean().nullable()();
  TextColumn get chunkPunctuationSetId => text().nullable()();
  // 角色工作模式：'chat' | 'tool'，null 为聊天模式（ADR0097）
  TextColumn get agentMode => text().nullable()();

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

@DriftDatabase(tables: [
  Conversations,
  Messages,
  MessageProjectionMappings,
  MessageBlocks,
  Providers,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 26;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await _ensureAutoReplyClaimTable();
        await _ensureContextMemoryTables();
        await _ensureMessageStateTable();
        await _ensureVoiceCallTables();
        await _ensureAgentTaskTables();
        await _ensureTokenUsageTables();
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
        // v21 -> v22: 语音通话记录与逐句转写（ADR0074），只存本机不同步
        if (from < 22) {
          await _ensureVoiceCallTables();
        }
        // v22 -> v23: 角色壁纸宽窄屏截取
        if (from < 23) {
          await _safeAddColumn(
              'conversations', 'chat_background_framing TEXT');
        }
        // v23 -> v24: 杂活 Agent 任务、待转告与已消费的控制事件（ADR0088），只存本机
        if (from < 24) {
          await _ensureAgentTaskTables();
        }
        // v24 -> v25: 角色工作模式（ADR0097）
        if (from < 25) {
          await _safeAddColumn('conversations', 'agent_mode TEXT');
        }
        // v25 -> v26: 图片预览大小、语音默认展开、隐藏用户头像与气泡分段改为按联系人
        if (from < 26) {
          await _safeAddColumn('conversations', 'image_preview_scale REAL');
          await _safeAddColumn('conversations',
              'expand_audio_text INTEGER CHECK (expand_audio_text IN (0, 1))');
          await _safeAddColumn('conversations',
              'hide_user_avatar INTEGER CHECK (hide_user_avatar IN (0, 1))');
          await _safeAddColumn('conversations',
              'chunk_enabled INTEGER CHECK (chunk_enabled IN (0, 1))');
          await _safeAddColumn('conversations',
              'filter_punctuation INTEGER CHECK (filter_punctuation IN (0, 1))');
          await _safeAddColumn(
              'conversations', 'chunk_punctuation_set_id TEXT');
        }
      },
      // 打开时维护本机表、索引与清理触发器，不改变user_version。
      beforeOpen: (_) async {
        await _runWithBusyRetry(
          () => transaction(() async {
            // 旧同步架构已退役；现行 cloud/LAN tracking 不依赖这些表。
            await customStatement('DROP TABLE IF EXISTS sync_scopes');
            await customStatement('DROP TABLE IF EXISTS sync_cursors');
            await customStatement('DROP TABLE IF EXISTS pending_operations');
          }),
        );
        await AppDataMigration.rewriteDatabase(this);
        await _ensureChatEntryIndexes();
        await _ensureAutoReplyClaimCompletion();
        await _ensureProactiveCallTable();
        await _ensureTokenUsageTables();
        await _runWithBusyRetry(
          () => customStatement('''
CREATE TRIGGER IF NOT EXISTS memory_items_delete_fts
AFTER DELETE ON memory_items
BEGIN
  DELETE FROM memory_items_fts WHERE item_id = OLD.id;
END
'''),
        );
      },
    );
  }

  Future<void> _ensureChatEntryIndexes() => _runWithBusyRetry(() =>
      transaction(() async {
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
      }));

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

  /// 语音通话（ADR0074）：每通电话一行，逐句转写单独存放，不进 messages。
  /// 聊天里只落一条带 callRecord 的消息指向 call_sessions.id。
  /// 由 SqliteCallRecordStore 以参数化 SQL 访问；不同步。
  Future<void> _ensureVoiceCallTables() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS call_sessions (
  id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  started_at INTEGER NOT NULL,
  ended_at INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL
)''');
    await customStatement('''
CREATE INDEX IF NOT EXISTS call_sessions_conversation
ON call_sessions(conversation_id, started_at)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS call_turns (
  call_id TEXT NOT NULL REFERENCES call_sessions(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role TEXT NOT NULL,
  text TEXT NOT NULL,
  interrupted INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (call_id, seq)
)''');
  }

  /// 杂活 Agent（ADR0088）：任务状态机、待转告的回执、已消费的控制事件与
  /// 总开关。由 AgentTaskStore 以参数化 SQL 访问；只存本机，不同步——回执
  /// 本身是一条随聊天同步的消息。
  Future<void> _ensureAgentTaskTables() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS agent_tasks (
  id TEXT PRIMARY KEY NOT NULL,
  request_key TEXT UNIQUE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  instruction TEXT NOT NULL,
  status TEXT NOT NULL,
  frozen INTEGER NOT NULL DEFAULT 0,
  notify TEXT NOT NULL,
  receipt_seq INTEGER NOT NULL DEFAULT 0,
  question_receipt_id TEXT,
  pending_receipt TEXT,
  side_effect_uncertain INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)''');
    await customStatement('''
CREATE INDEX IF NOT EXISTS agent_tasks_status ON agent_tasks(status, created_at)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS agent_task_deliveries (
  receipt_id TEXT PRIMARY KEY NOT NULL,
  task_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  state TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS agent_task_controls (
  control_id TEXT PRIMARY KEY NOT NULL,
  task_id TEXT NOT NULL,
  consumed_at INTEGER NOT NULL
)''');
    await customStatement('''
CREATE TABLE IF NOT EXISTS agent_task_switch (
  id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  enabled INTEGER NOT NULL,
  generation INTEGER NOT NULL
)''');
  }

  /// 主动回复触发器执行权认领表：前台轮询与后台 WorkManager 发送前
  /// 必须先认领，认领失败即另一方正在执行或已送达（见 AutoReplyClaimStore）。
  /// 不走 drift 表定义（仅 raw SQL 访问），避免为单一互斥表引入 codegen。
  Future<void> _ensureAutoReplyClaimTable() async {
    await customStatement('''
CREATE TABLE IF NOT EXISTS auto_reply_trigger_claims (
  trigger_id TEXT NOT NULL PRIMARY KEY,
  claimed_by TEXT NOT NULL,
  claimed_at INTEGER NOT NULL,
  completed_at INTEGER,
  message_id TEXT
)
''');
  }

  /// 主动来电记录（方案 12 §13，ProactiveCallLedger）：前台、WorkManager 与
  /// 通知回调共用的本机互斥表，同认领表只走 raw SQL、每次打开时建表，不升
  /// schema 版本，也不同步。
  Future<void> _ensureProactiveCallTable() => _runWithBusyRetry(
    () => transaction(() async {
      await customStatement('''
CREATE TABLE IF NOT EXISTS proactive_calls (
  trigger_id TEXT NOT NULL PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  opening_line TEXT NOT NULL,
  rang_at INTEGER NOT NULL,
  answer_until INTEGER NOT NULL,
  state TEXT NOT NULL,
  confirmed INTEGER NOT NULL DEFAULT 0,
  settled_at INTEGER
)
''');
      // Tables from before `confirmed` (2026-10-14): their calls were all
      // delivered, so they count as confirmed. A duplicate column means another
      // isolate added it first.
      final columns = await customSelect(
        'PRAGMA table_info(proactive_calls)',
      ).get();
      if (columns.any((row) => row.data['name'] == 'confirmed')) return;
      await _safeAddColumn(
        'proactive_calls',
        'confirmed INTEGER NOT NULL DEFAULT 1',
      );
    }),
  );

  /// 认领租约（2026-10-12）给旧表补 completed_at 与 message_id：本地互斥表，
  /// 不升 schema 版本，每次打开时按列是否存在补齐。旧记录视为已完成，不会被
  /// 接管。
  Future<void> _ensureAutoReplyClaimCompletion() async {
    try {
      await _runWithBusyRetry(() => transaction(() async {
        final columns = await customSelect(
          'PRAGMA table_info(auto_reply_trigger_claims)',
        ).get();
        if (columns.isEmpty) return;
        final names = {for (final row in columns) row.data['name']};
        if (!names.contains('completed_at')) {
          await customStatement(
            'ALTER TABLE auto_reply_trigger_claims '
            'ADD COLUMN completed_at INTEGER',
          );
          await customStatement(
            'UPDATE auto_reply_trigger_claims SET completed_at = claimed_at',
          );
        }
        if (!names.contains('message_id')) {
          await customStatement(
            'ALTER TABLE auto_reply_trigger_claims ADD COLUMN message_id TEXT',
          );
        }
      }));
    } on SqliteException {
      // 另一连接已补齐列时可继续；锁冲突耗尽或其他失败且缺列则向上传递。
      final after = await customSelect(
        'PRAGMA table_info(auto_reply_trigger_claims)',
      ).get();
      final names = {for (final row in after) row.data['name']};
      if (!names.contains('completed_at') || !names.contains('message_id')) {
        rethrow;
      }
    }
  }

  /// Local billing rows are shared by foreground and headless connections.
  Future<void> _ensureTokenUsageTables() => _runWithBusyRetry(
    () => transaction(() async {
      await customStatement('''CREATE TABLE IF NOT EXISTS token_usage_entries (
        id TEXT PRIMARY KEY NOT NULL, device_id TEXT NOT NULL,
        device_name TEXT NOT NULL, conversation_id TEXT, turn_id TEXT,
        round_index INTEGER, purpose TEXT NOT NULL, provider_id TEXT NOT NULL,
        model TEXT NOT NULL, input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0,
        is_estimated INTEGER NOT NULL DEFAULT 0, priced INTEGER NOT NULL DEFAULT 0,
        currency TEXT NOT NULL DEFAULT 'USD', cost_micros INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER, created_at INTEGER NOT NULL
      )''');
      await customStatement('CREATE INDEX IF NOT EXISTS token_usage_entries_time '
          'ON token_usage_entries(created_at)');
      await customStatement('CREATE INDEX IF NOT EXISTS token_usage_entries_model_time '
          'ON token_usage_entries(provider_id,model,created_at)');
      await customStatement('CREATE INDEX IF NOT EXISTS token_usage_entries_conv_time '
          'ON token_usage_entries(conversation_id,created_at)');
      await customStatement('''CREATE TABLE IF NOT EXISTS token_usage_archives (
        bucket_key TEXT PRIMARY KEY NOT NULL, device_id TEXT NOT NULL,
        device_name TEXT NOT NULL, period TEXT NOT NULL, period_start_ms INTEGER NOT NULL,
        provider_id TEXT NOT NULL, model TEXT NOT NULL, purpose TEXT NOT NULL,
        conversation_id TEXT NOT NULL DEFAULT '', request_count INTEGER NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cached_input_tokens INTEGER NOT NULL DEFAULT 0,
        cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        reasoning_tokens INTEGER NOT NULL DEFAULT 0,
        estimated_count INTEGER NOT NULL DEFAULT 0,
        priced_usd_micros INTEGER NOT NULL DEFAULT 0,
        priced_cny_micros INTEGER NOT NULL DEFAULT 0,
        unpriced_input_tokens INTEGER NOT NULL DEFAULT 0,
        unpriced_output_tokens INTEGER NOT NULL DEFAULT 0,
        unpriced_cached_tokens INTEGER NOT NULL DEFAULT 0,
        unpriced_cache_write_tokens INTEGER NOT NULL DEFAULT 0,
        price_currency TEXT, is_priced INTEGER NOT NULL DEFAULT 0,
        period_end_ms INTEGER, components TEXT
      )''');
    }),
  );

  /// Retry the complete transaction, never a partially applied billing write.
  Future<void> tokenUsageTransaction(Future<void> Function() action) =>
      _runWithBusyRetry(() => transaction(action));

  Future<void> _runWithBusyRetry(Future<void> Function() action) async {
    // 前后台连接同时打开时，事务先回滚释放锁，再有界异步重试。
    for (var attempt = 0;; attempt++) {
      try {
        await action();
        return;
      } on SqliteException catch (error) {
        if ((error.resultCode != 5 && error.resultCode != 6) || attempt >= 6) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
      }
    }
  }

  Future<void> _safeAddColumn(String table, String columnDef) async {
    try {
      await customStatement('ALTER TABLE $table ADD COLUMN $columnDef');
    } on SqliteException catch (error) {
      // 另一连接或历史版本已补过同名列时可继续，其余失败必须中止迁移。
      if (!error.message.toLowerCase().contains('duplicate column')) {
        rethrow;
      }
    }
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await appDataDirectory();
    final file = File(p.join(dbFolder.path, 'aicove.db'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        db.execute('PRAGMA busy_timeout = 5000');
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
