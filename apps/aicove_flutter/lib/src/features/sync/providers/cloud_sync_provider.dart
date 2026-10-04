import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/database/database_provider.dart';
import '../../../core/media/media_store.dart';
import '../../account/domain/account_port.dart';
import '../../account/providers/account_provider.dart';
import '../../chat/chat_providers.dart';
import '../../chat/services/conversation_short_window_store.dart';
import '../../plugins/plugin_providers.dart';
import '../../settings/app_settings.dart';
import '../../plugins/image/drawing_preset_provider.dart';
import '../../agent_context/providers/preset_recipe_provider.dart';
import '../data/cloud_api.dart';
import '../data/cloud_document.dart';
import '../data/cloud_local_store.dart';
import '../data/cloud_sync_engine.dart';
import '../data/cloud_sync_scheduler.dart';
import '../data/device_names.dart';

export '../data/cloud_sync_engine.dart' show CloudProgress;

final cloudSyncProvider =
    StateNotifierProvider<CloudSyncController, CloudProgress>((ref) {
      final controller = CloudSyncController(ref);
      ref.listen(
        accountProvider.select((state) => state.connection),
        (_, next) => controller.connect(next),
      );
      unawaited(controller.connect(ref.read(accountProvider).connection));
      return controller;
    });

class CloudSyncController extends StateNotifier<CloudProgress> {
  CloudSyncController(this.ref) : super(const CloudProgress('登录后可开启云同步'));
  final Ref ref;
  CloudSyncEngine? _engine;
  CloudSyncScheduler? _scheduler;
  CloudApi? _api;
  AccountConnection? _connected;
  String? _token;
  Future<void>? _connecting;
  int _generation = 0;
  Timer? _timelineRefreshTimer;
  bool _timelineRefreshRunning = false;
  final Set<String> _pendingTimelineIds = {};

  Future<void> connect(AccountConnection? connection) {
    if (_token == connection?.token) return _connecting ?? Future.value();
    _token = connection?.token;
    final current = _connected;
    if (_api != null &&
        connection != null &&
        connection.hasSession &&
        current != null &&
        current.owns(connection.server, connection.user)) {
      // A renewed token for the same account keeps the running engine.
      _api!.updateToken(connection.token!);
      _connected = connection;
      return synchronizeIfDue();
    }
    _api = null;
    _connected = null;
    final generation = ++_generation;
    _scheduler?.close();
    _scheduler = null;
    _timelineRefreshTimer?.cancel();
    _timelineRefreshTimer = null;
    _pendingTimelineIds.clear();
    _engine?.close();
    _engine = null;
    if (connection?.hasSession != true) {
      state = const CloudProgress('登录后可继续同步，本地数据已保留');
      return Future.value();
    }
    return _connecting = () async {
      try {
        final preferences = await SharedPreferences.getInstance();
        final documents = await getApplicationDocumentsDirectory();
        final support = await getApplicationSupportDirectory();
        if (!mounted || generation != _generation) return;
        final media = await MediaStore.shared;
        if (!mounted || generation != _generation) return;
        final local = CloudLocalStore(
          ref.read(databaseProvider),
          preferences,
          documents,
          support,
        );
        _api = CloudApi(connection!);
        _connected = connection;
        _engine = CloudSyncEngine(
          local,
          _api!,
          media,
          cloudObjectId(
            '${connection.server}/${connection.user.id}/${connection.user.uniqueId}',
          ),
          onProgress: (progress) {
            if (mounted && generation == _generation) state = progress;
          },
          onApplied: (kinds) {
            if (!mounted || generation != _generation) return;
            handleApplied(kinds);
          },
        );
        await publishDeviceName(preferences, media.deviceId);
        final engine = _engine!;
        _scheduler = CloudSyncScheduler(local, () async {
          await engine.synchronize();
          return mounted && state.error == null;
        })..start();
      } catch (_) {
        if (mounted && generation == _generation) {
          state = const CloudProgress('云同步初始化失败，请稍后重试');
        }
      }
    }();
  }

  void handleApplied(Set<String> kinds) {
    if (kinds.any(
      const {
        'messages',
        'message_blocks',
        'message_projection_mappings',
        'conversations',
        'media_assets',
      }.contains,
    )) {
      _pendingTimelineIds.addAll(
        ref.read(conversationTimelineCacheProvider).loadedConversationIds,
      );
      _scheduleTimelineRefresh();
    }
    if (kinds.contains('plugin_presets')) {
      ref.invalidate(tavernPluginSettingsProvider);
      ref.invalidate(presetRecipeListProvider);
      ref.invalidate(presetRecipeProvider);
    }
    if (kinds.contains('settings')) {
      ref.invalidate(appSettingsProvider);
      ref.invalidate(ttsPluginConfigProvider);
      ref.invalidate(triggerPluginConfigProvider);
      ref.invalidate(stickerPluginConfigProvider);
      ref.invalidate(imagePluginConfigProvider);
      ref.invalidate(drawingPresetCatalogProvider);
      ref.invalidate(timeAwarenessPluginConfigProvider);
    }
  }

  // Coalesce committed sync batches without blocking transport or reading
  // unopened conversations. A busy conversation is retried after generation.
  void _scheduleTimelineRefresh() {
    if (!mounted || _pendingTimelineIds.isEmpty) return;
    if (_timelineRefreshRunning || _timelineRefreshTimer != null) return;
    final generation = _generation;
    _timelineRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      _timelineRefreshTimer = null;
      unawaited(_refreshTimelines(generation));
    });
  }

  Future<void> _refreshTimelines(int generation) async {
    if (!mounted || generation != _generation) return;
    _timelineRefreshRunning = true;
    final ids = Set<String>.of(_pendingTimelineIds);
    _pendingTimelineIds.removeAll(ids);
    try {
      final deferred = await ref
          .read(conversationTimelineCacheProvider)
          .refreshConversationsFromRawStore(
            ids,
            canRefresh: (id) =>
                mounted &&
                generation == _generation &&
                !ref.read(conversationSendingProvider(id)),
          );
      if (mounted && generation == _generation) {
        _pendingTimelineIds.addAll(deferred);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        state = const CloudProgress('消息已保存，聊天窗口刷新失败，正在重试');
        _pendingTimelineIds.addAll(ids);
      }
    } finally {
      _timelineRefreshRunning = false;
      if (mounted) _scheduleTimelineRefresh();
    }
  }

  Future<Map<String, dynamic>> conflicts() async {
    await _connecting;
    if (_engine == null) throw const CloudSyncFailure('请先登录账号');
    return _engine!.previewConflicts();
  }

  Future<void> resolve(
    Map<String, dynamic> preview,
    String id,
    bool incoming,
  ) async {
    await _engine?.resolveConflict(preview, id, incoming: incoming);
  }

  Future<void> resolveAll(
    Map<String, dynamic> preview,
    Map<String, bool> useIncoming, {
    void Function(int done, int total)? onProgress,
  }) async {
    await _engine?.resolveConflicts(
      preview,
      useIncoming,
      onProgress: onProgress,
    );
  }

  String? get deviceId => _engine?.media.deviceId;

  Future<void> enable() async {
    await _connecting;
    try {
      await _engine?.enable();
    } catch (_) {
      /* Engine publishes a safe error. */
    }
  }

  /// Manual sync: always runs a round now.
  Future<void> synchronize() async {
    try {
      await _scheduler?.synchronize();
    } catch (_) {
      /* Retry on the next timer. */
    }
  }

  /// Launch/resume: runs only when the next automatic round is due.
  Future<void> synchronizeIfDue() async {
    try {
      await _scheduler?.synchronizeIfDue();
    } catch (_) {
      /* Retry on the next timer. */
    }
  }

  Future<void> pause() async {
    await _engine?.pause();
    if (mounted) state = const CloudProgress('自动同步已暂停');
  }

  @override
  void dispose() {
    _generation++;
    _scheduler?.close();
    _timelineRefreshTimer?.cancel();
    _engine?.close();
    super.dispose();
  }
}
