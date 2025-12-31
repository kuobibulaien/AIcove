/// TTS 待处理管理器 - 管理 TTS 音频生成的异步流程
///
/// 职责：
/// - 管理 pending TTS 事件
/// - 处理 TTS 超时
/// - 创建和替换占位消息
/// - 监听 TTS 处理完成事件
///
/// 遵循 DRY 原则：从 ChatActions 中提取的 TTS 相关逻辑
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';
import '../id_gen.dart';
import '../conversation_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../plugins/plugin_providers.dart';
import '../../../core/models/message_block.dart';
import '../../../core/models/block_status.dart';
import '../../../core/app_logger.dart';

/// TTS 音频处理结果
class TtsAudioResult {
  final Message? message;
  final bool success;
  final String? error;

  const TtsAudioResult.success([this.message])
      : success = true,
        error = null;

  const TtsAudioResult.failure([this.error])
      : success = false,
        message = null;
}

/// 待处理的 TTS 音频信息
class PendingTtsAudio {
  final String convId;
  final String placeholderId;
  final String? originalText;
  final Completer<TtsAudioResult> completer;

  PendingTtsAudio({
    required this.convId,
    required this.placeholderId,
    this.originalText,
    required this.completer,
  });
}

/// TTS 待处理管理器
class TtsPendingManager {
  TtsPendingManager(this._ref, this._ttsManager) {
    _setupProcessedListener();
  }

  final Ref _ref;
  final TtsPlayerManager _ttsManager;

  static const Duration _ttsTimeout = Duration(seconds: 30);
  final Map<String, PendingTtsAudio> _pendingEvents = {};
  StreamSubscription<TtsPlayItem>? _subscription;

  /// 设置 TTS 处理完成监听器
  void _setupProcessedListener() {
    _subscription = _ttsManager.processedStream.listen((item) {
      unawaited(_handleProcessed(item));
    });
    _ref.onDispose(() {
      _subscription?.cancel();
    });
  }

  /// 处理 TTS 完成事件
  Future<void> _handleProcessed(TtsPlayItem item) async {
    _log('tts:processed', {
      'eventId': item.id,
      'hasUrl': (item.audioUrl?.isNotEmpty ?? false),
      'status': item.status.toString(),
      'error': item.error,
    });

    final pending = _pendingEvents.remove(item.event.id);
    if (pending == null) return;

    if (pending.completer.isCompleted) return;

    final audioUrl = item.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      pending.completer.complete(const TtsAudioResult.failure('empty_url'));
      return;
    }

    final text = pending.originalText?.isNotEmpty == true
        ? pending.originalText!
        : ((item.event.data['originalText'] as String?)?.trim() ??
            (item.event.data['text'] as String?)?.trim() ??
            '');

    // 就地替换占位语音条
    try {
      await _ref.read(conversationsProvider.notifier).updateOne(
        pending.convId,
        (c) {
          final updated = c.messages.map((m) {
            if (m.id != pending.placeholderId) return m;
            final audioBlock = AudioBlock(
              messageId: m.id,
              url: audioUrl,
              text: text.isNotEmpty ? text : null,
              status: BlockStatus.success,
            );
            return Message.fromBlocks(
              id: m.id,
              role: m.role,
              blocks: [audioBlock],
              createdAt: m.createdAt,
              status: 'sent',
            );
          }).toList();
          return c.copyWith(
            messages: updated,
            updatedAt: DateTime.now(),
            lastMessage: '[语音]',
            lastMessageTime: DateTime.now(),
          );
        },
      );
    } catch (_) {}

    pending.completer.complete(const TtsAudioResult.success(null));
  }

  /// 创建 TTS 占位消息
  Message createPlaceholder({
    required String convId,
    String? displayText,
  }) {
    final placeholderId = genId('msg');
    return Message.fromBlocks(
      id: placeholderId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: placeholderId,
          url: '', // 占位：未就绪，UI 显示加载态
          text: displayText,
          status: BlockStatus.pending,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sending',
    );
  }

  /// 注册并等待 TTS 事件完成
  Future<List<TtsAudioResult>> registerAndWait(
    String convId,
    List<PluginEvent> events, {
    required String placeholderId,
  }) {
    final futures = <Future<TtsAudioResult>>[];
    for (final event in events) {
      final original = (event.data['originalText'] as String?)?.trim();
      final fallback = (event.data['text'] as String?)?.trim();
      final completer = Completer<TtsAudioResult>();
      _pendingEvents[event.id] = PendingTtsAudio(
        convId: convId,
        placeholderId: placeholderId,
        originalText: original?.isNotEmpty == true ? original : fallback,
        completer: completer,
      );

      // 超时保护
      Future.delayed(_ttsTimeout, () async {
        final p = _pendingEvents.remove(event.id);
        if (p != null && !p.completer.isCompleted) {
          _log('tts:timeout', {'eventId': event.id, 'convId': convId}, level: 'WARN');
          p.completer.complete(const TtsAudioResult.failure('timeout'));
          try {
            await removePlaceholder(convId, placeholderId);
          } catch (_) {}
        }
      });

      futures.add(completer.future);
    }
    if (futures.isEmpty) {
      return Future.value(const []);
    }
    return Future.wait(futures);
  }

  /// 取消待处理的 TTS 事件
  Future<void> cancelPending(
    Iterable<PluginEvent> events, {
    bool stopPlayer = false,
  }) async {
    for (final event in events) {
      final pending = _pendingEvents.remove(event.id);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(const TtsAudioResult.failure('cancelled'));
      }
    }
    if (stopPlayer) {
      await _ttsManager.stop();
      _ttsManager.clearQueue();
    }
  }

  /// 移除占位消息
  Future<void> removePlaceholder(String convId, String placeholderId) async {
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) => c.copyWith(
        messages: [
          for (final m in c.messages)
            if (m.id != placeholderId) m,
        ],
      ),
    );
  }

  /// 添加 TTS 事件到播放管理器
  Future<void> addEventsToPlayer(List<PluginEvent> events) async {
    await _ttsManager.addEvents(events);
  }

  /// 日志辅助
  void _log(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final metadata = <String, dynamic>{};
    data.forEach((k, v) {
      if (v != null) {
        if (v is String && v.length > 200) {
          metadata[k] = '${v.substring(0, 200)}...';
        } else {
          metadata[k] = v;
        }
      }
    });

    switch (level.toUpperCase()) {
      case 'WARN':
        AppLogger.warning('TtsPendingManager', name, metadata: metadata);
        break;
      case 'ERROR':
        AppLogger.error('TtsPendingManager', name, metadata: metadata);
        break;
      default:
        AppLogger.info('TtsPendingManager', name, metadata: metadata);
    }
  }
}

/// Provider 定义
final ttsPendingManagerProvider = Provider((ref) {
  final ttsManager = ref.read(ttsPlayerManagerProvider);
  return TtsPendingManager(ref, ttsManager);
});
