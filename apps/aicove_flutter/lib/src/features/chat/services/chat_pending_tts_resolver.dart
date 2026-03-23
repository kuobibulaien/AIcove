library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_providers.dart' show chatStatusProvider, ChatStatus;
import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../../core/app_logger.dart';
import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import 'chat_history_store.dart';

typedef StoreMutationEnqueuer = Future<void> Function(
  Future<void> Function() action,
);
typedef PendingTtsFallbackNotifier = void Function(String reason);

class ChatPendingTtsResolver {
  ChatPendingTtsResolver({
    required Ref ref,
    required TtsPlayerManager? ttsManager,
    required StoreMutationEnqueuer enqueueStoreMutation,
    PendingTtsFallbackNotifier? onTtsFallback,
  })  : _ref = ref,
        _ttsManager = ttsManager,
        _enqueueStoreMutation = enqueueStoreMutation,
        _onTtsFallback = onTtsFallback;

  final Ref _ref;
  final TtsPlayerManager? _ttsManager;
  final StoreMutationEnqueuer _enqueueStoreMutation;
  final PendingTtsFallbackNotifier? _onTtsFallback;

  static const Duration _ttsTimeout = Duration(seconds: 30);

  static bool isPendingPlaceholder(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is AudioBlock &&
        (block.url.isEmpty || block.status == BlockStatus.pending) &&
        (block.text?.trim().isNotEmpty ?? false);
  }

  Message buildPendingPlaceholderMessage(
    String ttsText, {
    String? messageId,
    DateTime? createdAt,
    String? sourceMessageId,
  }) {
    final finalId =
        (messageId ?? '').trim().isEmpty ? genId('msg') : messageId!.trim();
    return Message.fromBlocks(
      id: finalId,
      role: 'assistant',
      sourceMessageId: sourceMessageId,
      blocks: [
        AudioBlock(
          messageId: finalId,
          url: '',
          text: ttsText,
          status: BlockStatus.pending,
        ),
      ],
      createdAt: createdAt ?? DateTime.now(),
      status: 'sending',
    );
  }

  Future<void> resolvePendingMessages({
    required String convId,
    required List<Message> messages,
    TraceLogger? trace,
  }) async {
    if (messages.isEmpty) return;
    await Future.wait([
      for (final message in messages)
        () async {
          try {
            await resolveSinglePendingMessage(
              convId: convId,
              message: message,
            );
          } catch (e) {
            AppLogger.error('ChatPendingTtsResolver', '并发流式 TTS 回填失败',
                metadata: {
                  'convId': convId,
                  'messageId': message.id,
                  'error': e.toString(),
                });
          }
        }(),
    ]);
    trace?.note('流式 TTS 占位已原位更新', metadata: {
      'convId': convId,
      'count': messages.length,
    });
  }

  Future<void> resolveSinglePendingMessage({
    required String convId,
    required Message message,
  }) async {
    final audioBlocks = message.blocks?.whereType<AudioBlock>().toList();
    final block = (audioBlocks != null && audioBlocks.isNotEmpty)
        ? audioBlocks.first
        : null;
    final ttsText = block?.text?.trim() ?? '';
    if (ttsText.isEmpty) return;

    _ref.read(chatStatusProvider.notifier).state = ChatStatus.generatingVoice;
    var shouldFallbackToText = false;
    try {
      final audioUrl = await _convertTtsText(ttsText);
      if (audioUrl != null && audioUrl.isNotEmpty) {
        final success = await _updatePendingMessage(
          convId: convId,
          message: Message.fromBlocks(
            id: message.id,
            role: message.role,
            sourceMessageId: message.sourceMessageId,
            blocks: [
              AudioBlock(
                messageId: message.id,
                url: audioUrl,
                text: ttsText,
                durationSeconds: block?.durationSeconds,
                status: BlockStatus.success,
              ),
            ],
            createdAt: message.createdAt,
            status: 'sent',
          ),
          phase: 'audio_success',
        );
        if (success) {
          return;
        }
        AppLogger.warning('ChatPendingTtsResolver', '流式 TTS 原位更新失败，回退文本补位',
            metadata: {
              'messageId': message.id,
              'textLength': ttsText.length,
            });
        shouldFallbackToText = true;
      } else {
        AppLogger.warning('ChatPendingTtsResolver', '流式 TTS 占位生成失败，回退文本补位',
            metadata: {
              'messageId': message.id,
              'textLength': ttsText.length,
            });
        shouldFallbackToText = true;
      }
    } catch (e) {
      AppLogger.error('ChatPendingTtsResolver', '流式 TTS 占位异常，回退文本补位',
          metadata: {
            'messageId': message.id,
            'error': e.toString(),
          });
      _onTtsFallback?.call('convert_error');
      shouldFallbackToText = true;
    }
    if (!shouldFallbackToText) {
      return;
    }
    await _updatePendingMessage(
      convId: convId,
      message: Message.text(
        id: message.id,
        role: message.role,
        sourceMessageId: message.sourceMessageId,
        content: ttsText,
        createdAt: message.createdAt,
        status: 'sent',
      ),
      phase: 'text_fallback',
      notifyFallback: false,
    );
  }

  Future<String?> _convertTtsText(String text) async {
    final manager = _ttsManager;
    if (manager == null) return null;

    final eventId = DateTime.now().microsecondsSinceEpoch.toString();
    final event = PluginEvent(
      pluginId: 'tts',
      type: 'tts_convert',
      data: {
        'text': text,
        'originalText': text,
      },
      id: eventId,
    );
    final resultFuture = manager.processedStream.firstWhere(
      (item) => item.event.id == eventId,
    );
    await manager.addEvents([event]);
    try {
      final item = await resultFuture.timeout(_ttsTimeout);
      if (item.status == TtsPlayItemStatus.completed &&
          item.audioUrl != null &&
          item.audioUrl!.isNotEmpty) {
        return item.audioUrl;
      }
      return null;
    } on TimeoutException {
      AppLogger.warning('ChatPendingTtsResolver', 'TTS 生成超时', metadata: {
        'eventId': eventId,
        'textLength': text.length,
      });
      return null;
    }
  }

  Future<bool> _updatePendingMessage({
    required String convId,
    required Message message,
    required String phase,
    bool notifyFallback = true,
  }) async {
    try {
      await _enqueueStoreMutation(() {
        return _ref.read(chatHistoryStoreProvider).updateMessage(
              conversationId: convId,
              message: message,
            );
      });
      return true;
    } catch (e) {
      AppLogger.error('ChatPendingTtsResolver', '流式 TTS 占位写回失败', metadata: {
        'convId': convId,
        'messageId': message.id,
        'phase': phase,
        'error': e.toString(),
      });
      if (notifyFallback) {
        _onTtsFallback?.call('update_error');
      }
      return false;
    }
  }
}
