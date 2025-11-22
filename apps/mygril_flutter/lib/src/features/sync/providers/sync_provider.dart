import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/api_client.dart';
import '../data/local_database.dart';
import '../repositories/sync_repository.dart';
import '../models/sync_models.dart';
import 'auth_provider.dart';

/// 同步状态
class SyncState {
  final bool isSyncing;
  final bool autoSyncEnabled;
  final DateTime? lastSyncTime;
  final String? error;
  final Map<String, int> syncCounts; // 各类数据的同步数量

  SyncState({
    this.isSyncing = false,
    this.autoSyncEnabled = true,
    this.lastSyncTime,
    this.error,
    this.syncCounts = const {},
  });

  SyncState copyWith({
    bool? isSyncing,
    bool? autoSyncEnabled,
    DateTime? lastSyncTime,
    String? error,
    Map<String, int>? syncCounts,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      error: error,
      syncCounts: syncCounts ?? this.syncCounts,
    );
  }
}

/// 本地数据库Provider
final localDbProvider = Provider<LocalSyncDatabase>((ref) {
  return LocalSyncDatabase.instance;
});

/// 同步Repository Provider
final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final localDb = ref.watch(localDbProvider);
  return SyncRepository(apiClient: apiClient, localDb: localDb);
});

/// 同步Notifier
class SyncNotifier extends StateNotifier<SyncState> {
  final SyncRepository _repository;
  final Ref _ref;
  Timer? _autoSyncTimer;

  SyncNotifier(this._repository, this._ref) : super(SyncState()) {
    _startAutoSync();
  }

  /// 启动自动同步
  void _startAutoSync() {
    _autoSyncTimer?.cancel();

    // 每5分钟自动同步一次
    _autoSyncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      final authState = _ref.read(authProvider);
      if (authState.isLoggedIn && state.autoSyncEnabled) {
        syncAll();
      }
    });
  }

  /// 立即同步所有数据
  Future<void> syncAll() async {
    // 检查是否已登录
    final authState = _ref.read(authProvider);
    if (!authState.isLoggedIn) {
      state = state.copyWith(error: '未登录，无法同步');
      return;
    }

    if (state.isSyncing) {
      print('⚠️  已经在同步中，跳过');
      return;
    }

    state = state.copyWith(isSyncing: true, error: null);
    print('🔄 开始全量同步...');

    try {
      final results = await _repository.syncAll();

      // 统计同步数量
      final counts = <String, int>{};
      results.forEach((key, result) {
        if (result.success) {
          counts[key] = result.syncedCount;
        }
      });

      state = state.copyWith(
        isSyncing: false,
        lastSyncTime: DateTime.now(),
        syncCounts: counts,
      );

      print('✅ 全量同步完成: $counts');
    } catch (e) {
      state = state.copyWith(
        isSyncing: false,
        error: '同步失败: ${e.toString()}',
      );
      print('❌ 同步失败: $e');
    }
  }

  /// 同步联系人
  Future<void> syncContacts() async {
    final authState = _ref.read(authProvider);
    if (!authState.isLoggedIn) return;

    print('🔄 同步联系人...');
    final result = await _repository.syncContacts();

    if (result.success) {
      print('✅ 联系人同步完成: ${result.syncedCount}');
    } else {
      print('❌ 联系人同步失败: ${result.error}');
    }
  }

  /// 同步消息
  Future<void> syncMessages({String? contactId}) async {
    final authState = _ref.read(authProvider);
    if (!authState.isLoggedIn) return;

    print('🔄 同步消息...');
    final result = await _repository.syncMessages(contactId: contactId);

    if (result.success) {
      print('✅ 消息同步完成: ${result.syncedCount}');
    } else {
      print('❌ 消息同步失败: ${result.error}');
    }
  }

  /// 切换自动同步
  void toggleAutoSync() {
    state = state.copyWith(autoSyncEnabled: !state.autoSyncEnabled);
    if (state.autoSyncEnabled) {
      _startAutoSync();
    } else {
      _autoSyncTimer?.cancel();
    }
  }

  /// 清除错误
  void clearError() {
    state = state.copyWith(error: null);
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    super.dispose();
  }
}

/// 同步Provider
final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final repository = ref.watch(syncRepositoryProvider);
  return SyncNotifier(repository, ref);
});

/// 同步状态Provider（从服务器获取）
final remoteSyncStatusProvider = FutureProvider<SyncStatus?>((ref) async {
  final authState = ref.watch(authProvider);
  if (!authState.isLoggedIn) return null;

  final repository = ref.watch(syncRepositoryProvider);
  return await repository.getSyncStatus();
});
