import '../data/api_client.dart';
import '../data/local_database.dart';
import '../models/sync_models.dart';

/// 同步结果
class SyncResult {
  final bool success;
  final String? error;
  final int syncedCount;

  SyncResult({
    required this.success,
    this.error,
    this.syncedCount = 0,
  });

  factory SyncResult.success({int count = 0}) =>
      SyncResult(success: true, syncedCount: count);

  factory SyncResult.failure(String error) =>
      SyncResult(success: false, error: error);
}

/// 同步Repository
class SyncRepository {
  final ApiClient apiClient;
  final LocalSyncDatabase localDb;

  SyncRepository({
    required this.apiClient,
    required this.localDb,
  });

  // ============ 联系人同步 ============

  /// 同步联系人
  Future<SyncResult> syncContacts() async {
    try {
      // 1. 上传本地未同步的联系人
      final unsyncedContacts = await localDb.getUnsyncedContacts();
      if (unsyncedContacts.isNotEmpty) {
        final uploadData = unsyncedContacts.map((c) => c.toJson()).toList();
        final uploadResponse = await apiClient.syncContacts(uploadData);

        // 标记为已同步
        final syncedIds = unsyncedContacts.map((c) => c.contactId).toList();
        await localDb.markContactsAsSynced(syncedIds);

        print('✅ 上传了 ${unsyncedContacts.length} 个联系人');
      }

      // 2. 从服务器拉取新数据
      final lastSync = await localDb.getLastSyncTime('contacts');
      final response = await apiClient.getContacts(
        since: lastSync?.toIso8601String(),
      );

      final contacts = (response['contacts'] as List)
          .map((json) => ContactSync.fromJson(json as Map<String, dynamic>))
          .toList();

      // 3. 保存到本地
      if (contacts.isNotEmpty) {
        await localDb.batchInsertContacts(contacts);
        print('✅ 从服务器拉取了 ${contacts.length} 个联系人');
      }

      // 4. 更新同步时间
      await localDb.updateLastSyncTime('contacts', DateTime.now());

      return SyncResult.success(count: unsyncedContacts.length + contacts.length);
    } catch (e) {
      print('❌ 联系人同步失败: $e');
      return SyncResult.failure(e.toString());
    }
  }

  // ============ 消息同步 ============

  /// 同步消息
  Future<SyncResult> syncMessages({String? contactId, int batchSize = 100}) async {
    try {
      int totalSynced = 0;

      // 1. 上传本地未同步的消息（分批）
      while (true) {
        final unsyncedMessages = await localDb.getUnsyncedMessages(limit: batchSize);
        if (unsyncedMessages.isEmpty) break;

        final uploadData = unsyncedMessages.map((m) => m.toJson()).toList();
        final uploadResponse = await apiClient.syncMessages(uploadData);

        // 标记为已同步
        final syncedIds = unsyncedMessages.map((m) => m.messageId).toList();
        await localDb.markMessagesAsSynced(syncedIds);

        totalSynced += unsyncedMessages.length;
        print('✅ 上传了 ${unsyncedMessages.length} 条消息');

        // 如果本批次不足batchSize，说明已经全部上传完
        if (unsyncedMessages.length < batchSize) break;
      }

      // 2. 从服务器拉取新消息
      final lastSync = await localDb.getLastSyncTime('messages');
      final response = await apiClient.getMessages(
        contactId: contactId,
        since: lastSync?.toIso8601String(),
        limit: batchSize,
      );

      final messages = (response['messages'] as List)
          .map((json) => MessageSync.fromJson(json as Map<String, dynamic>))
          .toList();

      // 3. 保存到本地
      if (messages.isNotEmpty) {
        await localDb.batchInsertMessages(messages);
        totalSynced += messages.length;
        print('✅ 从服务器拉取了 ${messages.length} 条消息');
      }

      // 4. 更新同步时间
      await localDb.updateLastSyncTime('messages', DateTime.now());

      return SyncResult.success(count: totalSynced);
    } catch (e) {
      print('❌ 消息同步失败: $e');
      return SyncResult.failure(e.toString());
    }
  }

  // ============ 全量同步 ============

  /// 同步所有数据
  Future<Map<String, SyncResult>> syncAll() async {
    final results = <String, SyncResult>{};

    // 依次同步各类数据
    results['contacts'] = await syncContacts();
    results['messages'] = await syncMessages();
    // TODO: 添加设置同步
    // results['settings'] = await syncSettings();

    return results;
  }

  // ============ 同步状态 ============

  /// 获取同步状态
  Future<SyncStatus?> getSyncStatus() async {
    try {
      final response = await apiClient.getSyncStatus();
      return SyncStatus.fromJson(response);
    } catch (e) {
      print('❌ 获取同步状态失败: $e');
      return null;
    }
  }

  /// 检查是否需要同步
  Future<bool> needsSync() async {
    // 检查是否有未同步的数据
    final unsyncedContacts = await localDb.getUnsyncedContacts();
    if (unsyncedContacts.isNotEmpty) return true;

    final unsyncedMessages = await localDb.getUnsyncedMessages(limit: 1);
    if (unsyncedMessages.isNotEmpty) return true;

    // 检查距离上次同步是否超过5分钟
    final lastContactsSync = await localDb.getLastSyncTime('contacts');
    final lastMessagesSync = await localDb.getLastSyncTime('messages');

    final now = DateTime.now();
    if (lastContactsSync == null ||
        now.difference(lastContactsSync).inMinutes > 5) {
      return true;
    }
    if (lastMessagesSync == null ||
        now.difference(lastMessagesSync).inMinutes > 5) {
      return true;
    }

    return false;
  }
}
