/// (注释已丢失)
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
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  BoolColumn get isMuted => boolean().withDefault(const Constant(false))();
  BoolColumn get notificationSound =>
      boolean().withDefault(const Constant(true))();
  TextColumn get enabledPlugins =>
      text().nullable()(); // JSON array of plugin IDs

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

/// (注释已丢失)
class MessageBlocks extends Table {
  TextColumn get id => text()();
  TextColumn get messageId => text().references(Messages, #id)();
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

/// 记忆表（有效记忆 + 回收站记忆）
///
/// (注释已丢失)
/// (注释已丢失)
class Memories extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()(); // (注释已丢失)
  TextColumn get embedding => text().nullable()(); // 向量，JSON格式存储
  TextColumn get layer =>
      text().withDefault(const Constant('L3'))(); // L1/L2/L3/L4
  TextColumn get category =>
      text().withDefault(const Constant('daily_chatter'))(); // AI分类
  TextColumn get conversationId =>
      text().references(Conversations, #id).nullable()(); // (注释已丢失)
  TextColumn get contentHash => text().nullable()(); // 去重哈希
  BoolColumn get needsEnrichment =>
      boolean().withDefault(const Constant(false))(); // 被召回后待重丰富

  // (注释已丢失)
  RealColumn get persistenceP =>
      real().withDefault(const Constant(0.5))(); // (注释已丢失)
  RealColumn get emotionE =>
      real().withDefault(const Constant(0.0))(); // (注释已丢失)
  RealColumn get infoI => real().withDefault(const Constant(0.5))(); // (注释已丢失)
  RealColumn get judgeJ =>
      real().withDefault(const Constant(0.5))(); // J 综合判断

  // (注释已丢失)
  RealColumn get infoImportance =>
      real().withDefault(const Constant(0.5))(); // (注释已丢失)
  RealColumn get timeCoef =>
      real().withDefault(const Constant(1.0))(); // (注释已丢失)
  RealColumn get importance =>
      real().withDefault(const Constant(0.5))(); // (注释已丢失)

  // 系统维护字段
  IntColumn get useCount =>
      integer().withDefault(const Constant(0))(); // (注释已丢失)
  IntColumn get lastActiveAt =>
      integer().nullable()(); // (注释已丢失)

  // (注释已丢失)
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 同步字段
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get syncState =>
      text().withDefault(const Constant('local'))(); // local/synced/modified

  // (注释已丢失)
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// (注释已丢失)
class SummarizationRecords extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get dateKey => text()(); // yyyy-MM-dd（归属日期）
  TextColumn get roundKey => text()(); // (注释已丢失)
  IntColumn get roundIndex => integer().withDefault(const Constant(0))();
  IntColumn get firstMsgTime => integer()();
  IntColumn get lastMsgTime => integer()();
  IntColumn get messageCount => integer()();
  BoolColumn get summarized => boolean().withDefault(const Constant(false))();
  IntColumn get summarizedAt => integer().nullable()();
  TextColumn get errorMessage => text().nullable()();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
        {conversationId, dateKey, roundKey},
      ];
}

/// (注释已丢失)
class MemoryTombstones extends Table {
  TextColumn get tombstoneId => text()();
  TextColumn get memoryId => text()(); // (注释已丢失)
  TextColumn get reason =>
      text()(); // evicted / replaced / user_delete / conflict_patch
  TextColumn get payloadHash => text().nullable()(); // (注释已丢失)

  // (注释已丢失)
  IntColumn get deletedAt => integer()();
  IntColumn get purgeAt => integer()();
  IntColumn get cloudSyncedAt => integer().nullable()(); // (注释已丢失)

  @override
  Set<Column> get primaryKey => {tombstoneId};
}

/// (注释已丢失)
///
/// (注释已丢失)
/// (注释已丢失)
class Diaries extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id)(); // 关联角色
  IntColumn get date => integer()(); // (注释已丢失)
  TextColumn get content => text()(); // (注释已丢失)
  TextColumn get embedding => text().nullable()(); // 向量，JSON格式存储

  // (注释已丢失)
  TextColumn get mood => text().nullable()(); // 当天心情
  TextColumn get keywords => text().nullable()(); // (注释已丢失)

  // 同步字段
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get syncState => text().withDefault(const Constant('local'))();

  // (注释已丢失)
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
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
  Diaries,
  SummarizationRecords,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await _ensureMemoryFts();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // (注释已丢失)
        if (from < 2) {
          await m.createTable(memories);
          await m.createTable(memoryTombstones);
        }
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
        if (from < 5) {
          await m.createTable(diaries);
        }
        // (注释已丢失)
        if (from < 6) {
          await _safeAddColumn(
              'messages', 'summarized INTEGER NOT NULL DEFAULT 0');
          await _safeAddColumn('messages', 'summarized_at INTEGER');

          await _safeAddColumn("memories", "layer TEXT NOT NULL DEFAULT 'L3'");
          await _safeAddColumn(
              "memories", "category TEXT NOT NULL DEFAULT 'daily_chatter'");
          await _safeAddColumn('memories', 'conversation_id TEXT');
          await _safeAddColumn('memories', 'content_hash TEXT');
          await _safeAddColumn(
              'memories', 'needs_enrichment INTEGER NOT NULL DEFAULT 0');

          await m.createTable(summarizationRecords);
          await _ensureMemoryFts();
          await _backfillMemoryFts();
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
      },
    );
  }

  Future<void> _safeAddColumn(String table, String columnDef) async {
    try {
      await customStatement('ALTER TABLE $table ADD COLUMN $columnDef');
    } catch (_) {
      // (注释已丢失)
    }
  }

  Future<void> _ensureMemoryFts() async {
    await customStatement('''
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
USING fts5(memory_id, conversation_id, tokenized_content)
''');
  }

  Future<void> _backfillMemoryFts() async {
    // (注释已丢失)
    await customStatement('DELETE FROM memory_fts');
    final rows = await customSelect('''
SELECT id, COALESCE(conversation_id, '') AS conversation_id, content
FROM memories
WHERE deleted_at IS NULL
''').get();

    await batch((b) {
      for (final row in rows) {
        final memoryId = row.read<String>('id');
        final conversationId = row.read<String>('conversation_id');
        final content = row.read<String>('content');
        final tokenized = _tokenizeForFts(content);
        b.customStatement(
          '''
INSERT INTO memory_fts(memory_id, conversation_id, tokenized_content)
VALUES (?, ?, ?)
''',
          [memoryId, conversationId, tokenized],
        );
      }
    });
  }

  static bool _isHanCodeUnit(int codeUnit) {
    return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
        (codeUnit >= 0x3400 && codeUnit <= 0x4DBF);
  }

  static bool _isAsciiWordCodeUnit(int codeUnit) {
    return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
        codeUnit == 0x5F;
  }

  static String _tokenizeForFts(String text) {
    final input = text.trim();
    if (input.isEmpty) return '';

    final tokens = <String>[];
    var i = 0;
    while (i < input.length) {
      final cu = input.codeUnitAt(i);

      if (_isHanCodeUnit(cu)) {
        final start = i;
        i++;
        while (i < input.length && _isHanCodeUnit(input.codeUnitAt(i))) {
          i++;
        }
        final run = input.substring(start, i);
        if (run.length == 1) {
          tokens.add(run);
        } else {
          for (var j = 0; j < run.length - 1; j++) {
            tokens.add(run.substring(j, j + 2));
          }
        }
        continue;
      }

      if (_isAsciiWordCodeUnit(cu)) {
        final start = i;
        i++;
        while (i < input.length && _isAsciiWordCodeUnit(input.codeUnitAt(i))) {
          i++;
        }
        tokens.add(input.substring(start, i).toLowerCase());
        continue;
      }

      i++;
    }

    return tokens.join(' ');
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
