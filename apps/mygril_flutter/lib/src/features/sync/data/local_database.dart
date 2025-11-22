import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/sync_models.dart';

/// 本地数据库（用于云同步）
class LocalSyncDatabase {
  static final LocalSyncDatabase instance = LocalSyncDatabase._();
  static Database? _database;

  LocalSyncDatabase._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'mygril_sync.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // 联系人表
    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        contact_id TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL,
        avatar_url TEXT,
        character_data TEXT,
        is_synced INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    // 消息表
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id TEXT UNIQUE NOT NULL,
        contact_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        metadata TEXT,
        is_synced INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    // 同步元数据表
    await db.execute('''
      CREATE TABLE sync_metadata (
        data_type TEXT PRIMARY KEY,
        last_sync_at TEXT
      )
    ''');

    // 创建索引
    await db.execute(
        'CREATE INDEX idx_messages_contact ON messages(contact_id)');
    await db.execute('CREATE INDEX idx_messages_created ON messages(created_at)');
  }

  // ============ 联系人操作 ============

  /// 获取未同步的联系人
  Future<List<ContactSync>> getUnsyncedContacts() async {
    final db = await database;
    final maps = await db.query(
      'contacts',
      where: 'is_synced = ?',
      whereArgs: [0],
    );

    return maps.map((map) => _contactFromMap(map)).toList();
  }

  /// 插入或更新联系人
  Future<void> upsertContact(ContactSync contact, {bool isSynced = false}) async {
    final db = await database;
    await db.insert(
      'contacts',
      {
        'contact_id': contact.contactId,
        'name': contact.name,
        'avatar_url': contact.avatarUrl,
        'character_data': contact.characterData?.toString(),
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': contact.isDeleted ? 1 : 0,
        'updated_at': contact.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量插入联系人
  Future<void> batchInsertContacts(List<ContactSync> contacts) async {
    final db = await database;
    final batch = db.batch();

    for (final contact in contacts) {
      batch.insert(
        'contacts',
        {
          'contact_id': contact.contactId,
          'name': contact.name,
          'avatar_url': contact.avatarUrl,
          'character_data': contact.characterData?.toString(),
          'is_synced': 1,
          'is_deleted': contact.isDeleted ? 1 : 0,
          'updated_at': contact.updatedAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
  }

  /// 标记联系人为已同步
  Future<void> markContactsAsSynced(List<String> contactIds) async {
    final db = await database;
    final batch = db.batch();

    for (final id in contactIds) {
      batch.update(
        'contacts',
        {'is_synced': 1},
        where: 'contact_id = ?',
        whereArgs: [id],
      );
    }

    await batch.commit(noResult: true);
  }

  // ============ 消息操作 ============

  /// 获取未同步的消息
  Future<List<MessageSync>> getUnsyncedMessages({int limit = 100}) async {
    final db = await database;
    final maps = await db.query(
      'messages',
      where: 'is_synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
      limit: limit,
    );

    return maps.map((map) => _messageFromMap(map)).toList();
  }

  /// 插入消息
  Future<void> insertMessage(MessageSync message, {bool isSynced = false}) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'message_id': message.messageId,
        'contact_id': message.contactId,
        'role': message.role,
        'content': message.content,
        'metadata': message.metadata?.toString(),
        'is_synced': isSynced ? 1 : 0,
        'is_deleted': message.isDeleted ? 1 : 0,
        'created_at': message.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// 批量插入消息
  Future<void> batchInsertMessages(List<MessageSync> messages) async {
    final db = await database;
    final batch = db.batch();

    for (final message in messages) {
      batch.insert(
        'messages',
        {
          'message_id': message.messageId,
          'contact_id': message.contactId,
          'role': message.role,
          'content': message.content,
          'metadata': message.metadata?.toString(),
          'is_synced': 1,
          'is_deleted': message.isDeleted ? 1 : 0,
          'created_at': message.createdAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    await batch.commit(noResult: true);
  }

  /// 标记消息为已同步
  Future<void> markMessagesAsSynced(List<String> messageIds) async {
    final db = await database;
    final batch = db.batch();

    for (final id in messageIds) {
      batch.update(
        'messages',
        {'is_synced': 1},
        where: 'message_id = ?',
        whereArgs: [id],
      );
    }

    await batch.commit(noResult: true);
  }

  // ============ 同步元数据 ============

  /// 获取最后同步时间
  Future<DateTime?> getLastSyncTime(String dataType) async {
    final db = await database;
    final maps = await db.query(
      'sync_metadata',
      where: 'data_type = ?',
      whereArgs: [dataType],
    );

    if (maps.isEmpty) return null;
    return DateTime.parse(maps.first['last_sync_at'] as String);
  }

  /// 更新最后同步时间
  Future<void> updateLastSyncTime(String dataType, DateTime time) async {
    final db = await database;
    await db.insert(
      'sync_metadata',
      {
        'data_type': dataType,
        'last_sync_at': time.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ============ 辅助方法 ============

  ContactSync _contactFromMap(Map<String, dynamic> map) {
    return ContactSync(
      contactId: map['contact_id'] as String,
      name: map['name'] as String,
      avatarUrl: map['avatar_url'] as String?,
      characterData: map['character_data'] != null
          ? {} // TODO: 解析JSON
          : null,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      isDeleted: (map['is_deleted'] as int) == 1,
    );
  }

  MessageSync _messageFromMap(Map<String, dynamic> map) {
    return MessageSync(
      messageId: map['message_id'] as String,
      contactId: map['contact_id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      metadata: map['metadata'] != null
          ? {} // TODO: 解析JSON
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
      isDeleted: (map['is_deleted'] as int) == 1,
    );
  }

  /// 清空所有数据
  Future<void> clearAll() async {
    final db = await database;
    await db.delete('contacts');
    await db.delete('messages');
    await db.delete('sync_metadata');
  }
}
