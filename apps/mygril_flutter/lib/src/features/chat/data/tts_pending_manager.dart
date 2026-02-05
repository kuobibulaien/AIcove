/// TTS 待处理管理器 - 管理 TTS 音频生成的异步流程
///
/// 职责：
/// - 管理 pending TTS 事件
/// - 处理 TTS 超时
/// - 创建和替换占位消息
/// - 监听 TTS 处理完成事件
///
/// 更新记录：
/// - 2025-12-31: 遵循 DRY 原则，从 ChatActions 中提取的 TTS 相关逻辑
/// - 2026-01-14: 添加 TTS 失败回退机制
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
import '../services/tts_fallback_notification.dart';

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

/// TTS 失败回退通知回调类型
typedef TtsFallbackNotifier = void Function(String reason);

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
  
  /// TTS 失败回退通知回调
  TtsFallbackNotifier? onTtsFallback;

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
    final text = pending.originalText?.isNotEmpty == true
        ? pending.originalText!
        : ((item.event.data['originalText'] as String?)?.trim() ??
            (item.event.data['text'] as String?)?.trim() ??
            '');

    // TTS 生成失败（空 URL），回退到文本消息
    if (audioUrl == null || audioUrl.isEmpty) {
      _log('tts:fallback', {
        'eventId': item.id,
        'reason': 'empty_url',
        'textLength': text.length,
      }, level: 'WARN');
      await _fallbackToTextMessage(
        convId: pending.convId,
        placeholderId: pending.placeholderId,
        text: text,
        reason: 'empty_url',
      );
      pending.completer.complete(const TtsAudioResult.failure('empty_url'));
      return;
    }

    // TTS 成功，就地替换占位语音条
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

  /// 回退到文本消息
  /// 
  /// 当 TTS 生成失败时，将占位语音消息替换为原始文本消息
  Future<void> _fallbackToTextMessage({
    required String convId,
    required String placeholderId,
    required String text,
    required String reason,
  }) async {
    // 如果文本为空，直接删除占位消息
    if (text.isEmpty) {
      await removePlaceholder(convId, placeholderId);
      return;
    }

    try {
      await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) {
          final updated = c.messages.map((m) {
            if (m.id != placeholderId) return m;
            // 替换为文本消息
            return Message(
              id: m.id,
              role: m.role,
              content: text,
              createdAt: m.createdAt,
              status: 'sent',
            );
          }).toList();
          return c.copyWith(
            messages: updated,
            updatedAt: DateTime.now(),
            lastMessage: text.length > 20 ? '${text.substring(0, 20)}...' : text,
            lastMessageTime: DateTime.now(),
          );
        },
      );
      
      // 触发通知回调
      onTtsFallback?.call(reason);
    } catch (e) {
      _log('tts:fallback_error', {'error': e.toString()}, level: 'ERROR');
      // 回退失败时，至少删除占位消息
      await removePlaceholder(convId, placeholderId);
    }
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
          // 超时时回退到文本消息，而不是直接删除
          final text = p.originalText ?? '';
          try {
            await _fallbackToTextMessage(
              convId: convId,
              placeholderId: placeholderId,
              text: text,
              reason: 'timeout',
            );
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
/// 注意：如果 TTS 插件不存在，返回 null 而不是抛异常
final ttsPendingManagerProvider = Provider<TtsPendingManager?>((ref) {
  final ttsManager = ref.read(ttsPlayerManagerProvider);
  if (ttsManager == null) {
    // TTS 插件不存在，返回 null
    return null;
  }
  
  final manager = TtsPendingManager(ref, ttsManager);
  
  // 连接到全局通知服务
  try {
    final notificationService = ref.read(ttsFallbackNotificationServiceProvider);
    manager.onTtsFallback = notificationService.notify;
  } catch (_) {
    // 服务未初始化，忽略
  }
  
  return manager;
});
