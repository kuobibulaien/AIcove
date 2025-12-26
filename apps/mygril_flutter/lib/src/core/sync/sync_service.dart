/// 云同步服务
library;

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../database/database.dart' hide Provider;
import '../database/database_provider.dart';

/// 同步状态
enum SyncStatus { idle, syncing, success, error }

/// 同步服务
class SyncService {
  final AppDatabase _db;
  final Dio _dio;
  final String _deviceId;

  SyncService(this._db, this._dio, this._deviceId);

  /// 获取或创建设备 ID
  static Future<String> getDeviceId(FlutterSecureStorage storage) async {
    var deviceId = await storage.read(key: 'device_id');
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await storage.write(key: 'device_id', value: deviceId);
    }
    return deviceId;
  }

  /// 获取同步游标
  Future<SyncCursor?> _getCursor() async {
    return (_db.select(_db.syncCursors)
          ..where((t) => t.deviceId.equals(_deviceId)))
        .getSingleOrNull();
  }

  /// 更新同步游标
  Future<void> _updateCursor({
    int? conversationsCursor,
    int? messagesCursor,
    int? providersCursor,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _getCursor();
    await _db.into(_db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion(
            deviceId: Value(_deviceId),
            conversationsCursor:
                Value(conversationsCursor ?? existing?.conversationsCursor ?? 0),
            messagesCursor: Value(messagesCursor ?? existing?.messagesCursor ?? 0),
            providersCursor: Value(providersCursor ?? existing?.providersCursor ?? 0),
            updatedAt: Value(now),
          ),
        );
  }

  /// 拉取远程变更
  Future<void> pull() async {
    final cursor = await _getCursor();
    final params = <String, dynamic>{};
    if (cursor != null) {
      params['conversations_cursor'] = cursor.conversationsCursor;
      params['messages_cursor'] = cursor.messagesCursor;
      params['providers_cursor'] = cursor.providersCursor;
    }

    final response = await _dio.get('/api/v1/sync/v2/pull', queryParameters: params);
    final data = response.data as Map<String, dynamic>;

    // 应用会话变更
    final conversations = data['conversations'] as List? ?? [];
    for (final conv in conversations) {
      await _applyConversation(conv as Map<String, dynamic>);
    }

    // 应用消息变更
    final messages = data['messages'] as List? ?? [];
    for (final msg in messages) {
      await _applyMessage(msg as Map<String, dynamic>);
    }

    // 应用渠道商变更
    final providers = data['providers'] as List? ?? [];
    for (final prov in providers) {
      await _applyProvider(prov as Map<String, dynamic>);
    }

    // 更新游标
    final cursors = data['cursors'] as Map<String, dynamic>?;
    if (cursors != null) {
      await _updateCursor(
        conversationsCursor: cursors['conversations'] as int?,
        messagesCursor: cursors['messages'] as int?,
        providersCursor: cursors['providers'] as int?,
      );
    }
  }

  /// 推送本地变更
  Future<void> push() async {
    // 获取待同步操作
    final pending = await (_db.select(_db.pendingOperations)
          ..where((t) => t.synced.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();

    if (pending.isEmpty) return;

    final operations = pending.map((op) {
      return {
        'op_id': op.opId,
        'op_type': op.opType,
        ...jsonDecode(op.opData) as Map<String, dynamic>,
      };
    }).toList();

    final response = await _dio.post(
      '/api/v1/sync/v2/push',
      data: {'operations': operations},
    );

    final results = response.data['results'] as List? ?? [];
    for (final result in results) {
      final opId = result['op_id'] as String;
      final status = result['status'] as String;
      if (status == 'ok' || status == 'duplicate') {
        // 标记为已同步
        await (_db.update(_db.pendingOperations)
              ..where((t) => t.opId.equals(opId)))
            .write(const PendingOperationsCompanion(synced: Value(true)));
      }
    }
  }

  /// 完整同步（先推后拉）
  Future<void> sync() async {
    await push();
    await pull();
  }

  /// 添加待同步操作
  Future<void> addPendingOperation(String opType, Map<String, dynamic> data) async {
    final opId = const Uuid().v4();
    await _db.into(_db.pendingOperations).insert(
          PendingOperationsCompanion(
            opId: Value(opId),
            opType: Value(opType),
            opData: Value(jsonEncode(data)),
            createdAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  // 应用远程会话到本地
  Future<void> _applyConversation(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final existing = await (_db.select(_db.conversations)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    final companion = ConversationsCompanion(
      id: Value(id),
      title: Value(data['title'] as String? ?? ''),
      displayName: Value(data['display_name'] as String? ?? ''),
      avatarUrl: Value(data['avatar_url'] as String?),
      characterImage: Value(data['character_image'] as String?),
      selfAddress: Value(data['self_address'] as String?),
      addressUser: Value(data['address_user'] as String?),
      voiceFile: Value(data['voice_file'] as String?),
      personaPrompt: Value(data['persona_prompt'] as String? ?? ''),
      defaultProvider: Value(data['default_provider'] as String?),
      sessionProvider: Value(data['session_provider'] as String?),
      isPinned: Value(data['is_pinned'] as bool? ?? false),
      isFavorite: Value(data['is_favorite'] as bool? ?? false),
      isMuted: Value(data['is_muted'] as bool? ?? false),
      notificationSound: Value(data['notification_sound'] as bool? ?? true),
      lastMessage: Value(data['last_message'] as String?),
      lastMessageTime: Value(data['last_message_time'] as int?),
      parentConversationId: Value(data['parent_conversation_id'] as String?),
      forkFromMessageId: Value(data['fork_from_message_id'] as String?),
      deletedAt: Value(data['deleted_at'] as int?),
      purgeAt: Value(data['purge_at'] as int?),
      createdAt: Value(data['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      updatedAt: Value(data['updated_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );

    if (existing == null) {
      await _db.into(_db.conversations).insert(companion);
    } else {
      await (_db.update(_db.conversations)..where((t) => t.id.equals(id)))
          .write(companion);
    }
  }

  // 应用远程消息到本地
  Future<void> _applyMessage(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final existing = await (_db.select(_db.messages)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    final companion = MessagesCompanion(
      id: Value(id),
      conversationId: Value(data['conversation_id'] as String),
      role: Value(data['role'] as String),
      content: Value(data['content'] as String? ?? ''),
      status: Value(data['status'] as String? ?? 'sent'),
      replacedBy: Value(data['replaced_by'] as String?),
      deletedAt: Value(data['deleted_at'] as int?),
      purgeAt: Value(data['purge_at'] as int?),
      createdAt: Value(data['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );

    if (existing == null) {
      await _db.into(_db.messages).insert(companion);
    } else {
      await (_db.update(_db.messages)..where((t) => t.id.equals(id)))
          .write(companion);
    }

    // 处理消息块
    final blocks = data['blocks'] as List? ?? [];
    for (final block in blocks) {
      await _applyMessageBlock(block as Map<String, dynamic>);
    }
  }

  // 应用远程消息块到本地
  Future<void> _applyMessageBlock(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final existing = await (_db.select(_db.messageBlocks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    final companion = MessageBlocksCompanion(
      id: Value(id),
      messageId: Value(data['message_id'] as String),
      type: Value(data['type'] as String),
      status: Value(data['status'] as String? ?? 'success'),
      data: Value(jsonEncode(data['data'] ?? {})),
      sortOrder: Value(data['sort_order'] as int? ?? 0),
      deletedAt: Value(data['deleted_at'] as int?),
      createdAt: Value(data['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );

    if (existing == null) {
      await _db.into(_db.messageBlocks).insert(companion);
    } else {
      await (_db.update(_db.messageBlocks)..where((t) => t.id.equals(id)))
          .write(companion);
    }
  }

  // 应用远程渠道商到本地
  Future<void> _applyProvider(Map<String, dynamic> data) async {
    final id = data['id'] as String;
    final existing = await (_db.select(_db.providers)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    final companion = ProvidersCompanion(
      id: Value(id),
      displayName: Value(data['display_name'] as String? ?? ''),
      apiBaseUrl: Value(data['api_base_url'] as String? ?? ''),
      enabled: Value(data['enabled'] as bool? ?? true),
      capabilities: Value(jsonEncode(data['capabilities'] ?? [])),
      customConfig: Value(jsonEncode(data['custom_config'] ?? {})),
      modelType: Value(data['model_type'] as String?),
      visibleModels: Value(jsonEncode(data['visible_models'] ?? [])),
      hiddenModels: Value(jsonEncode(data['hidden_models'] ?? [])),
      apiKeys: Value(jsonEncode(data['api_keys'] ?? [])),
      deletedAt: Value(data['deleted_at'] as int?),
      purgeAt: Value(data['purge_at'] as int?),
      createdAt: Value(data['created_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
      updatedAt: Value(data['updated_at'] as int? ?? DateTime.now().millisecondsSinceEpoch),
    );

    if (existing == null) {
      await _db.into(_db.providers).insert(companion);
    } else {
      await (_db.update(_db.providers)..where((t) => t.id.equals(id)))
          .write(companion);
    }
  }
}

/// SyncService Provider
final syncServiceProvider = FutureProvider<SyncService>((ref) async {
  final db = ref.watch(databaseProvider);
  const secureStorage = FlutterSecureStorage();
  final deviceId = await SyncService.getDeviceId(secureStorage);

  // TODO: 从设置中读取云端 URL
  final dio = Dio(BaseOptions(
    baseUrl: 'https://api.example.com', // 需要配置
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
  ));

  return SyncService(db, dio, deviceId);
});

/// 同步状态 Provider
final syncStatusProvider = StateProvider<SyncStatus>((ref) => SyncStatus.idle);
