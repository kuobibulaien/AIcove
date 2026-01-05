/// TTS 处理服务
/// 
/// 封装 TTS 事件监听、等待和消息更新逻辑。
/// 从 chat_actions.dart 提取，遵循单一职责原则。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';
import '../id_gen.dart';
import '../conversation_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../../core/models/message_block.dart';
import '../../../core/models/block_status.dart';
import 'chat_types.dart';
import 'chat_message_processor.dart';

/// TTS 处理服务
/// 
/// 管理 TTS 事件的注册、等待和消息更新
class ChatTtsHandler {
  final Ref _ref;
  final TtsPlayerManager _ttsManager;
  
  static const Duration _ttsTimeout = Duration(seconds: 30);
  final Map<String, PendingTtsAudio> _pendingTtsEvents = {};
  StreamSubscription<TtsPlayItem>? _ttsProcessedSubscription;

  ChatTtsHandler(this._ref)
      : _ttsManager = _ref.read(ttsPlayerManagerProvider) {
    _setupListener();
  }

  /// 初始化监听
  void _setupListener() {
    _ttsProcessedSubscription = _ttsManager.processedStream.listen((item) {
      unawaited(_handleTtsProcessed(item));
    });
    _ref.onDispose(() {
      _ttsProcessedSubscription?.cancel();
    });
  }

  /// 处理 TTS 完成事件
  Future<void> _handleTtsProcessed(TtsPlayItem item) async {
    final pending = _pendingTtsEvents.remove(item.event.id);
    if (pending == null || pending.completer.isCompleted) return;

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

  /// 注册并等待 TTS 事件完成
  Future<List<TtsAudioResult>> registerAndWaitForTtsEvents(
    String convId,
    List<PluginEvent> events,
    {required String placeholderId}
  ) {
    final futures = <Future<TtsAudioResult>>[];
    for (final event in events) {
      final original = (event.data['originalText'] as String?)?.trim();
      final fallback = (event.data['text'] as String?)?.trim();
      final completer = Completer<TtsAudioResult>();
      _pendingTtsEvents[event.id] = PendingTtsAudio(
        convId: convId,
        placeholderId: placeholderId,
        originalText: original?.isNotEmpty == true ? original : fallback,
        completer: completer,
      );

      Future.delayed(_ttsTimeout, () async {
        final p = _pendingTtsEvents.remove(event.id);
        if (p != null && !p.completer.isCompleted) {
          p.completer.complete(const TtsAudioResult.failure('timeout'));
          try {
            await removePlaceholderMessage(convId, placeholderId);
          } catch (_) {}
        }
      });

      futures.add(completer.future);
    }
    if (futures.isEmpty) return Future.value(const []);
    return Future.wait(futures);
  }

  /// 准备助手消息交付
  Future<AssistantDeliveryResult> prepareAssistantDelivery({
    required String convId,
    required List<Message> fallbackMessages,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
  }) async {
    final fallbackPreview = fallbackMessages.isNotEmpty 
        ? fallbackMessages.last.displayText 
        : replyText;

    if (!ttsEnabled) {
      return AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }
    
    final hasAudioInFallback = fallbackMessages.any(
      (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
    );
    if (hasAudioInFallback) {
      return AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }

    return _prepareDeliveryWithPending(
      convId: convId,
      fallbackMessages: fallbackMessages,
      replyText: replyText,
      pluginEvents: pluginEvents,
      fallbackPreview: fallbackPreview,
    );
  }

  /// 准备带占位消息的交付
  Future<AssistantDeliveryResult> _prepareDeliveryWithPending({
    required String convId,
    required List<Message> fallbackMessages,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required String fallbackPreview,
  }) async {
    final ttsEvents = pluginEvents.where((e) => e.type == 'tts_convert').toList();
    if (ttsEvents.isEmpty) {
      return AssistantDeliveryResult(
        messages: fallbackMessages,
        lastMessagePreview: fallbackPreview,
      );
    }

    final placeholderId = genId('msg');
    final ttsTexts = chatMessageProcessor.collectTtsTexts(replyText, pluginEvents);
    final placeholder = Message.fromBlocks(
      id: placeholderId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: placeholderId,
          url: '',
          text: ttsTexts.join('\n\n').trim().isNotEmpty ? ttsTexts.join('\n\n').trim() : null,
          status: BlockStatus.pending,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sending',
    );

    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) => c.copyWith(
        messages: [...c.messages, placeholder],
        updatedAt: DateTime.now(),
        lastMessage: '[语音生成中]',
        lastMessageTime: DateTime.now(),
      ),
    );

    unawaited(registerAndWaitForTtsEvents(convId, ttsEvents, placeholderId: placeholderId));

    return AssistantDeliveryResult(
      messages: fallbackMessages,
      lastMessagePreview: fallbackPreview,
      placeholderId: placeholder.id,
    );
  }

  /// 移除占位消息
  Future<void> removePlaceholderMessage(String convId, String placeholderId) async {
    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) => c.copyWith(
        messages: [for (final m in c.messages) if (m.id != placeholderId) m],
      ),
    );
  }
}

/// Provider
final chatTtsHandlerProvider = Provider((ref) => ChatTtsHandler(ref));
