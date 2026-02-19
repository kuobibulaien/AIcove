/// Drift 鏁版嵁搴撳畾涔夛紙鏂藉伐鎵嬪唽 4.x 瀵瑰簲鐨勬湰鍦拌〃缁撴瀯锛?
///
/// 杩愯浠ｇ爜鐢熸垚: flutter pub run build_runner build
library;

import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

/// 浼氳瘽/瑙掕壊鍗¤〃
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

  // 鍗曡鑹茶缃?
  TextColumn get defaultProvider => text().nullable()();
  TextColumn get sessionProvider => text().nullable()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  BoolColumn get isMuted => boolean().withDefault(const Constant(false))();
  BoolColumn get notificationSound =>
      boolean().withDefault(const Constant(true))();
  TextColumn get enabledPlugins =>
      text().nullable()(); // JSON array of plugin IDs

  // 浼氳瘽鎽樿缂撳瓨
  TextColumn get lastMessage => text().nullable()();
  IntColumn get lastMessageTime => integer().nullable()(); // unix ms
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();

  // 鍒嗘敮瀛楁
  TextColumn get parentConversationId => text().nullable()();
  TextColumn get forkFromMessageId => text().nullable()();

  // 鍐茬獊瀛楁
  TextColumn get conflictOf => text().nullable()();

  // 鍥炴敹绔欏瓧娈?
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 鏃堕棿鎴?
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 娑堟伅琛?
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get role => text()(); // 'user' | 'assistant'
  TextColumn get content => text()();
  TextColumn get status => text()
      .withDefault(const Constant('sent'))(); // 'sending' | 'sent' | 'failed'
  BoolColumn get summarized =>
      boolean().withDefault(const Constant(false))(); // 鏄惁宸茶璁板繂鎬荤粨
  IntColumn get summarizedAt => integer().nullable()(); // 鎬荤粨瀹屾垚鏃堕棿锛坲nix ms锛?

  // 閲嶇敓鎴愯鐩栧瓧娈?
  TextColumn get replacedBy => text().nullable()();

  // 鍐茬獊瀛楁
  TextColumn get conflictOf => text().nullable()();

  // 鍥炴敹绔欏瓧娈?
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 鏃堕棿鎴?
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 澶氭ā鎬佸唴瀹瑰潡琛?
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

/// 娓犻亾鍟嗛厤缃〃
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
      text().withDefault(const Constant('[]'))(); // JSON array锛堟湰鍦版槑鏂囷紝浜戠鍔犲瘑锛?

  // 鍐茬獊瀛楁
  TextColumn get conflictOf => text().nullable()();

  // 鍥炴敹绔欏瓧娈?
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 鏃堕棿鎴?
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 鍚屾鑼冨洿閰嶇疆琛?
class SyncScopes extends Table {
  TextColumn get enabledScopes => text()
      .withDefault(const Constant('["chat.history", "characters.cards"]'))();
  IntColumn get updatedAt => integer()();

  // 鍗曡琛紝鐢ㄥ浐瀹?id
  IntColumn get id => integer().withDefault(const Constant(1))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 鍚屾娓告爣琛紙璁板綍鍚屾浣嶇疆锛?
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

/// 寰呭悓姝ユ搷浣滈槦鍒楋紙绂荤嚎鏃舵殏瀛橈級
class PendingOperations extends Table {
  TextColumn get opId => text()();
  TextColumn get opType => text()();
  TextColumn get opData => text()(); // JSON
  IntColumn get createdAt => integer()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {opId};
}

/// 璁板繂琛紙鏈夋晥璁板繂 + 鍥炴敹绔欒蹇嗭級
///
/// 鏈湴涓婇檺鐢遍厤缃帶鍒讹紙榛樿 800锛夛紝瓒呴鏃舵寜鍒嗙被浼樺厛绾?+ use_count 鍋氬帇缂?娣樻卑
/// L1 涓?core_preference 璁板繂涓嶅弬涓庤嚜鍔ㄦ窐姹?
class Memories extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()(); // 璁板繂鏂囨湰锛堝璇濇憳瑕?浜嬪疄锛?
  TextColumn get embedding => text().nullable()(); // 鍚戦噺锛孞SON鏍煎紡瀛樺偍
  TextColumn get layer =>
      text().withDefault(const Constant('L3'))(); // L1/L2/L3/L4
  TextColumn get category =>
      text().withDefault(const Constant('daily_chatter'))(); // AI鍒嗙被
  TextColumn get conversationId =>
      text().references(Conversations, #id).nullable()(); // 鏃ф暟鎹彲绌?
  TextColumn get contentHash => text().nullable()(); // 鍘婚噸鍝堝笇
  BoolColumn get needsEnrichment =>
      boolean().withDefault(const Constant(false))(); // 琚彫鍥炲悗寰呴噸涓板瘜

  // AI 鎵撳垎椤癸紙0~1锛?
  RealColumn get persistenceP =>
      real().withDefault(const Constant(0.5))(); // P 鎸佷箙鎬?
  RealColumn get emotionE =>
      real().withDefault(const Constant(0.0))(); // E 鎯呯华鍊?
  RealColumn get infoI => real().withDefault(const Constant(0.5))(); // I 淇℃伅閲?
  RealColumn get judgeJ =>
      real().withDefault(const Constant(0.5))(); // J 缁煎悎鍒ゆ柇

  // 璁＄畻鍚庣殑閲嶈鎬у瓧娈?
  RealColumn get infoImportance =>
      real().withDefault(const Constant(0.5))(); // 淇℃伅閲嶈鎬?
  RealColumn get timeCoef =>
      real().withDefault(const Constant(1.0))(); // 鏃堕棿绯绘暟 (0.8~1)
  RealColumn get importance =>
      real().withDefault(const Constant(0.5))(); // 鏈€缁堥噸瑕佹€?

  // 绯荤粺缁存姢瀛楁
  IntColumn get useCount =>
      integer().withDefault(const Constant(0))(); // 琚敞鍏opK鐨勬鏁?
  IntColumn get lastActiveAt =>
      integer().nullable()(); // 鏈€鍚庤娉ㄥ叆鐨勬椂闂?(unix ms)

  // 鍥炴敹绔欏瓧娈?
  IntColumn get deletedAt => integer().nullable()();
  IntColumn get purgeAt => integer().nullable()();

  // 鍚屾瀛楁
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get syncState =>
      text().withDefault(const Constant('local'))(); // local/synced/modified

  // 鏃堕棿鎴?
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 鎬荤粨骞傜瓑璁板綍锛堟寜鏃?杞锛?
class SummarizationRecords extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get dateKey => text()(); // yyyy-MM-dd锛堝綊灞炴棩鏈燂級
  TextColumn get roundKey => text()(); // 骞傜瓑閿細day:date 鎴?sha1(date|start|end)
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

/// 璁板繂澧撶琛紙鐢ㄤ簬骞傜瓑銆侀槻閲嶅涓婁紶锛?
class MemoryTombstones extends Table {
  TextColumn get tombstoneId => text()();
  TextColumn get memoryId => text()(); // 瀵瑰簲鐨勮蹇?id
  TextColumn get reason =>
      text()(); // evicted / replaced / user_delete / conflict_patch
  TextColumn get payloadHash => text().nullable()(); // 鍙€夛紝鐢ㄤ簬骞傜瓑涓庤皟璇?

  // 鏃堕棿瀛楁
  IntColumn get deletedAt => integer()();
  IntColumn get purgeAt => integer()();
  IntColumn get cloudSyncedAt => integer().nullable()(); // 鎴愬姛涓婁紶澧撶鍒颁簯绔殑鏃堕棿

  @override
  Set<Column> get primaryKey => {tombstoneId};
}

/// 鏃ヨ琛?
///
/// 浠ヨ鑹茶瑙掕褰曟瘡澶╀笌鐢ㄦ埛鐨勪簰鍔紝浣滀负闀挎湡璁板繂瀛樺偍
/// 姣忓ぉ姣忎釜瑙掕壊鏈€澶氫竴绡囨棩璁?
class Diaries extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(Conversations, #id)(); // 鍏宠仈瑙掕壊
  IntColumn get date => integer()(); // 鏃ヨ鏃ユ湡锛堢簿纭埌澶╋紝unix ms锛?
  TextColumn get content => text()(); // 鏃ヨ鍐呭锛堣鑹茶瑙掞紝绗竴浜虹О锛?
  TextColumn get embedding => text().nullable()(); // 鍚戦噺锛孞SON鏍煎紡瀛樺偍

  // 鍏冩暟鎹?
  TextColumn get mood => text().nullable()(); // 褰撳ぉ蹇冩儏
  TextColumn get keywords => text().nullable()(); // 鍏抽敭璇嶆爣绛撅紝JSON鏁扮粍

  // 鍚屾瀛楁
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();
  TextColumn get syncState => text().withDefault(const Constant('local'))();

  // 鏃堕棿鎴?
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

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        await _ensureMemoryFts();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // v1 -> v2: 鏂板 memories 鍜?memory_tombstones 琛?
        if (from < 2) {
          await m.createTable(memories);
          await m.createTable(memoryTombstones);
        }
        // v2 -> v3: 鏂板 blurredBackground 鍒?
        if (from < 3) {
          await customStatement(
              'ALTER TABLE conversations ADD COLUMN blurred_background TEXT');
        }
        // v3 -> v4: 鏂板 enabledPlugins 鍒?
        if (from < 4) {
          await customStatement(
              'ALTER TABLE conversations ADD COLUMN enabled_plugins TEXT');
        }
        // v4 -> v5: 鏂板 diaries 鏃ヨ琛?
        if (from < 5) {
          await m.createTable(diaries);
        }
        // v5 -> v6: 璁板繂澧炲己锛堝垎灞傚瓧娈点€佹秷鎭€荤粨瀛楁銆佽疆娆″箓绛夈€丗TS锛?
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
      },
    );
  }

  Future<void> _safeAddColumn(String table, String columnDef) async {
    try {
      await customStatement('ALTER TABLE $table ADD COLUMN $columnDef');
    } catch (_) {
      // 骞傜瓑杩佺Щ锛氶噸澶嶆墽琛屾椂蹇界暐鈥渄uplicate column name鈥?
    }
  }

  Future<void> _ensureMemoryFts() async {
    await customStatement('''
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
USING fts5(memory_id, conversation_id, tokenized_content)
''');
  }

  Future<void> _backfillMemoryFts() async {
    // FTS5 铏氳〃瀵?memory_id 娌℃湁鍞竴绾︽潫锛屽厛娓呯┖鍐嶆寜缁熶竴鍒嗚瘝瑙勫垯鍥炲～銆?
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
        // 鍚敤澶栭敭鍜?WAL 妯″紡
        db.execute('PRAGMA foreign_keys = ON');
        db.execute('PRAGMA journal_mode = WAL');
      },
    );
  });
}
