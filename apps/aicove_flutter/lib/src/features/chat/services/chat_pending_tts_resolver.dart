library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_providers.dart' show chatStatusProvider, ChatStatus;
import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../plugins/tts/voice_request.dart';
import '../../plugins/tts/voice_preset_application.dart';
import '../../../core/app_logger.dart';
import '../../observability/frontend_diagnostics_port.dart';
import '../../observability/frontend_diagnostics_provider.dart';
import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import 'chat_history_store.dart';
import 'conversation_short_window_store.dart'
    show conversationTimelineCacheProvider;

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

  final Map<String, Future<void>> _inFlightResolutions =
      <String, Future<void>>{};

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
            await resolveSinglePendingMessage(convId: convId, message: message);
          } catch (e) {
            AppLogger.error(
              'ChatPendingTtsResolver',
              '并发流式 TTS 回填失败',
              metadata: {
                'convId': convId,
                'messageId': message.id,
                'error': e.toString(),
              },
            );
          }
        }(),
    ]);
    trace?.note(
      '流式 TTS 占位已原位更新',
      metadata: {'convId': convId, 'count': messages.length},
    );
  }

  Future<void> resolveSinglePendingMessage({
    required String convId,
    required Message message,
    void Function(String audioUrl, double? durationSeconds)? onAudioResolved,
    void Function(String text)? onTextFallback,
    bool persistResult = true,
    bool Function()? shouldApplyResult,
  }) async {
    final diagnostics = _ref.read(frontendDiagnosticsProvider);
    final context = diagnostics.child(
      diagnostics.forMessage(message.id) ??
          diagnostics.forMessage(message.sourceMessageIdOrSelf),
      FrontendStage.ttsRequested,
      conversationId: convId,
      messageId: message.id,
    );
    if (_ttsManager == null) {
      diagnostics.record(context, FrontendStage.ttsApplyDecision,
          messageId: message.id,
          facts: const DiagnosticFacts(
              phase: DiagnosticPhase.skip, reason: DiagnosticReason.noManager));
      return;
    }
    final existing = _inFlightResolutions[message.id];
    if (existing != null) {
      diagnostics.record(context, FrontendStage.ttsApplyDecision,
          messageId: message.id,
          facts: const DiagnosticFacts(
              phase: DiagnosticPhase.skip,
              reason: DiagnosticReason.joinedExisting));
      await existing;
      return;
    }
    diagnostics.bindMessage(message.id, context);
    final future = _doResolveSinglePendingMessage(
      diagnostics: diagnostics,
      diagnosticContext: context,
      convId: convId,
      message: message,
      onAudioResolved: onAudioResolved,
      onTextFallback: onTextFallback,
      persistResult: persistResult,
      shouldApplyResult: shouldApplyResult,
    );
    _inFlightResolutions[message.id] = future;
    try {
      await future;
    } finally {
      _inFlightResolutions.remove(message.id);
    }
  }

  Future<void> _doResolveSinglePendingMessage({
    required FrontendDiagnosticsPort diagnostics,
    required FrontendDiagnosticContext diagnosticContext,
    required String convId,
    required Message message,
    void Function(String audioUrl, double? durationSeconds)? onAudioResolved,
    void Function(String text)? onTextFallback,
    required bool persistResult,
    bool Function()? shouldApplyResult,
  }) async {
    final audioBlocks = message.blocks?.whereType<AudioBlock>().toList();
    final block = (audioBlocks != null && audioBlocks.isNotEmpty)
        ? audioBlocks.first
        : null;
    final ttsText = block?.text?.trim() ?? '';
    void record(FrontendStage stage, DiagnosticReason reason,
        {DiagnosticPhase phase = DiagnosticPhase.decision,
        Object? error,
        StackTrace? stack}) {
      diagnostics.record(diagnosticContext, stage,
          messageId: message.id,
          error: error,
          stackTrace: stack,
          facts: DiagnosticFacts(
              phase: phase,
              reason: reason,
              sourceMessageId: message.sourceMessageId,
              state: {
                'persistResult': persistResult,
                'textLength': ttsText.length
              }));
    }

    if (ttsText.isEmpty) {
      record(FrontendStage.ttsApplyDecision, DiagnosticReason.emptyText,
          phase: DiagnosticPhase.skip);
      return;
    }

    _ref.read(chatStatusProvider.notifier).state = ChatStatus.generatingVoice;
    var shouldFallbackToText = false;
    try {
      final audioUrl = await _convertTtsText(
          ttsText, diagnostics, diagnosticContext, message.id, convId);
      if (!(shouldApplyResult?.call() ?? true)) {
        record(FrontendStage.ttsApplyDecision, DiagnosticReason.ownerRejected,
            phase: DiagnosticPhase.skip);
        return;
      }
      if (audioUrl != null && audioUrl.isNotEmpty) {
        onAudioResolved?.call(audioUrl, block?.durationSeconds);
        if (!persistResult) {
          record(FrontendStage.ttsApplyDecision, DiagnosticReason.callbackOnly,
              phase: DiagnosticPhase.end);
          return;
        }
        final cached = await _ref
            .read(conversationTimelineCacheProvider)
            .findCachedMessageById(message.id, conversationId: convId);
        final effectiveSourceMessageId =
            (cached?.sourceMessageId?.trim().isNotEmpty ?? false)
                ? cached!.sourceMessageId
                : message.sourceMessageId;
        final success = await _updatePendingMessage(
          convId: convId,
          message: Message.fromBlocks(
            id: message.id,
            role: message.role,
            sourceMessageId: effectiveSourceMessageId,
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
          diagnostics: diagnostics,
          diagnosticContext: diagnosticContext,
        );
        if (success) {
          return;
        }
        AppLogger.warning(
          'ChatPendingTtsResolver',
          '流式 TTS 原位更新失败，回退文本补位',
          metadata: {'messageId': message.id, 'textLength': ttsText.length},
        );
        shouldFallbackToText = true;
      } else {
        AppLogger.warning(
          'ChatPendingTtsResolver',
          '流式 TTS 占位生成失败，回退文本补位',
          metadata: {'messageId': message.id, 'textLength': ttsText.length},
        );
        shouldFallbackToText = true;
      }
    } catch (e, stack) {
      record(FrontendStage.ttsFailed, DiagnosticReason.operationFailed,
          phase: DiagnosticPhase.error, error: e, stack: stack);
      if (!(shouldApplyResult?.call() ?? true)) {
        record(FrontendStage.ttsApplyDecision, DiagnosticReason.ownerRejected,
            phase: DiagnosticPhase.skip);
        return;
      }
      AppLogger.error(
        'ChatPendingTtsResolver',
        '流式 TTS 占位异常，回退文本补位',
        metadata: {'messageId': message.id, 'error': e.toString()},
      );
      _onTtsFallback?.call('convert_error');
      shouldFallbackToText = true;
    }
    if (!shouldFallbackToText) {
      return;
    }
    onTextFallback?.call(ttsText);
    record(FrontendStage.ttsApplyDecision, DiagnosticReason.fallbackText,
        phase: persistResult ? DiagnosticPhase.decision : DiagnosticPhase.end);
    if (!persistResult) return;
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
      diagnostics: diagnostics,
      diagnosticContext: diagnosticContext,
      notifyFallback: false,
    );
  }

  Future<String?> _convertTtsText(
      String text,
      FrontendDiagnosticsPort diagnostics,
      FrontendDiagnosticContext diagnosticContext,
      String messageId, String convId) async {
    final manager = _ttsManager;
    if (manager == null) return null;

    final eventId = genId('tts_evt');
    final event = PluginEvent(
      pluginId: 'tts',
      type: 'tts_convert',
      data: {
        'text': text,
        'originalText': text,
      },
      id: eventId,
    );
    final request = VoiceRequest.current ??
        await _ref.read(voicePresetApplicationProvider).forOwnerId(convId);
    if (request.ownerId != convId) throw StateError('语音请求角色不匹配，已阻止合成');
    if (request.error != null) throw StateError(request.error!);
    request.attach(event);
    final resultFuture = manager.processedStream.firstWhere(
      (item) => item.event.id == eventId,
    );
    diagnostics.record(diagnosticContext, FrontendStage.ttsSynthesisStarted,
        messageId: messageId,
        facts: DiagnosticFacts(
            phase: DiagnosticPhase.start, state: {'textLength': text.length}));
    await manager.addEvents([event]);
    try {
      final item = await resultFuture.timeout(_ttsTimeout);
      diagnostics.record(diagnosticContext, FrontendStage.ttsSynthesisResult,
          messageId: messageId,
          facts: DiagnosticFacts(
              phase: DiagnosticPhase.end,
              reason: item.status == TtsPlayItemStatus.completed
                  ? DiagnosticReason.providerCompleted
                  : DiagnosticReason.providerReturnedEmpty,
              state: {
                'hasAudio': item.audioUrl?.isNotEmpty ?? false,
                'completed': item.status == TtsPlayItemStatus.completed
              }));
      if (item.status == TtsPlayItemStatus.completed &&
          item.audioUrl != null &&
          item.audioUrl!.isNotEmpty) {
        return item.audioUrl;
      }
      return null;
    } on TimeoutException catch (error, stack) {
      diagnostics.record(diagnosticContext, FrontendStage.ttsFailed,
          messageId: messageId,
          error: error,
          stackTrace: stack,
          facts: const DiagnosticFacts(
              phase: DiagnosticPhase.error, reason: DiagnosticReason.timeout));
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
    required FrontendDiagnosticsPort diagnostics,
    required FrontendDiagnosticContext diagnosticContext,
    bool notifyFallback = true,
  }) async {
    try {
      await _enqueueStoreMutation(() {
        return _ref.read(chatHistoryStoreProvider).updateMessage(
              conversationId: convId,
              message: message,
            );
      });
      diagnostics.record(diagnosticContext, FrontendStage.ttsPersisted,
          messageId: message.id,
          facts: DiagnosticFacts(
              phase: DiagnosticPhase.end,
              reason: phase == 'text_fallback'
                  ? DiagnosticReason.fallbackText
                  : DiagnosticReason.persisted,
              sourceMessageId: message.sourceMessageId));
      return true;
    } catch (e, stack) {
      diagnostics.record(diagnosticContext, FrontendStage.ttsFailed,
          messageId: message.id,
          error: e,
          stackTrace: stack,
          facts: const DiagnosticFacts(
              phase: DiagnosticPhase.error,
              reason: DiagnosticReason.persistenceFailed));
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
