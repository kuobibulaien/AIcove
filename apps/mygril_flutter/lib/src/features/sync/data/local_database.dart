import 'package:drift/drift.dart';
import 'package:mygril_flutter/src/core/database/database.dart';
import '../models/sync_models.dart';

/// 兼容层：旧的 features/sync 模块本地库。
///
/// 说明：项目已切换到 Drift（见 `src/core/database` 和 `src/core/sync`）。
/// 为了保证工程可编译，这里不再依赖 sqflite。
///
/// 注意：该类仅用于让旧代码继续编译，避免“工程里还留着旧文件导致 analyze 失败”。
/// 如果你正在使用新的 `SyncService`，建议不要再调用本类的方法。
class LocalSyncDatabase {
  static final LocalSyncDatabase instance = LocalSyncDatabase._(AppDatabase());

  final AppDatabase _db;
  final Map<String, DateTime> _lastSyncTime = {};

  LocalSyncDatabase._(this._db);

  // ============ 兼容：联系人操作（映射到 Conversations） ============

  /// 获取未同步的联系人
  Future<List<ContactSync>> getUnsyncedContacts() async {
    // 新版同步机制使用 PendingOperations，本类不再维护 is_synced。
    return const [];
  }

  /// 插入或更新联系人
  Future<void> upsertContact(ContactSync contact, {bool isSynced = false}) async {
    final now = contact.updatedAt.millisecondsSinceEpoch;
    await _db.into(_db.conversations).insertOnConflictUpdate(
          ConversationsCompanion(
            id: Value(contact.contactId),
            title: Value(contact.name),
            displayName: Value(contact.name),
            avatarUrl: Value(contact.avatarUrl),
            createdAt: Value(now),
            updatedAt: Value(now),
            deletedAt: Value(contact.isDeleted ? now : null),
            purgeAt: Value(contact.isDeleted
                ? now + const Duration(days: 7).inMilliseconds
                : null),
          ),
        );
  }

  /// 批量插入联系人
  Future<void> batchInsertContacts(List<ContactSync> contacts) async {
    await _db.batch((batch) {
      for (final contact in contacts) {
        final now = contact.updatedAt.millisecondsSinceEpoch;
        batch.insert(
          _db.conversations,
          ConversationsCompanion(
            id: Value(contact.contactId),
            title: Value(contact.name),
            displayName: Value(contact.name),
            avatarUrl: Value(contact.avatarUrl),
            createdAt: Value(now),
            updatedAt: Value(now),
            deletedAt: Value(contact.isDeleted ? now : null),
            purgeAt: Value(contact.isDeleted
                ? now + const Duration(days: 7).inMilliseconds
                : null),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// 标记联系人为已同步
  Future<void> markContactsAsSynced(List<String> contactIds) async {
    // 新版同步机制使用 PendingOperations，本类不再维护 is_synced。
  }

  // ============ 兼容：消息操作（映射到 Messages） ============

  /// 获取未同步的消息
  Future<List<MessageSync>> getUnsyncedMessages({int limit = 100}) async {
    // 新版同步机制使用 PendingOperations，本类不再维护 is_synced。
    return const [];
  }

  /// 插入消息
  Future<void> insertMessage(MessageSync message, {bool isSynced = false}) async {
    final createdAt = message.createdAt.millisecondsSinceEpoch;
    await _db.into(_db.messages).insertOnConflictUpdate(
          MessagesCompanion(
            id: Value(message.messageId),
            conversationId: Value(message.contactId),
            role: Value(message.role),
            content: Value(message.content),
            createdAt: Value(createdAt),
            deletedAt: Value(message.isDeleted ? createdAt : null),
            purgeAt: Value(message.isDeleted
                ? createdAt + const Duration(days: 7).inMilliseconds
                : null),
          ),
        );
  }

  /// 批量插入消息
  Future<void> batchInsertMessages(List<MessageSync> messages) async {
    await _db.batch((batch) {
      for (final message in messages) {
        final createdAt = message.createdAt.millisecondsSinceEpoch;
        batch.insert(
          _db.messages,
          MessagesCompanion(
            id: Value(message.messageId),
            conversationId: Value(message.contactId),
            role: Value(message.role),
            content: Value(message.content),
            createdAt: Value(createdAt),
            deletedAt: Value(message.isDeleted ? createdAt : null),
            purgeAt: Value(message.isDeleted
                ? createdAt + const Duration(days: 7).inMilliseconds
                : null),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// 标记消息为已同步
  Future<void> markMessagesAsSynced(List<String> messageIds) async {
    // 新版同步机制使用 PendingOperations，本类不再维护 is_synced。
  }

  // ============ 同步元数据 ============

  /// 获取最后同步时间
  Future<DateTime?> getLastSyncTime(String dataType) async {
    return _lastSyncTime[dataType];
  }

  /// 更新最后同步时间
  Future<void> updateLastSyncTime(String dataType, DateTime time) async {
    _lastSyncTime[dataType] = time;
  }

  /// 清空所有数据
  Future<void> clearAll() async {
    // 为安全起见，这里不再执行“清空数据库”动作，避免误删主聊天数据。
    // 新版同步清理应由核心同步模块按回收站/到期清理策略处理。
  }
}
