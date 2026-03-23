library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_providers.dart' show chatStatusProvider, ChatStatus;
import '../domain/message.dart';
import '../domain/persona_prompt_codec.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/models/block_status.dart';
import '../../../core/models/message_block.dart';
import 'chat_history_store.dart';
import 'chat_request_message_builder.dart';
import 'conversation_short_window_store.dart';

class DeferredImageJob {
  const DeferredImageJob({
    required this.messageId,
    required this.prompt,
    required this.createdAt,
    this.sourceMessageId,
    this.failureAnchorMessageId,
  });

  final String messageId;
  final String prompt;
  final DateTime createdAt;
  final String? sourceMessageId;
  final String? failureAnchorMessageId;
}

class ChatDeferredImageDelivery {
  ChatDeferredImageDelivery({
    required Ref ref,
    required Future<void> Function(Future<void> Function())
        enqueueStoreMutation,
    required void Function(String label, Future<void> Function() task)
        runBackgroundTask,
  })  : _ref = ref,
        _enqueueStoreMutation = enqueueStoreMutation,
        _runBackgroundTask = runBackgroundTask;

  final Ref _ref;
  final Future<void> Function(Future<void> Function()) _enqueueStoreMutation;
  final void Function(String label, Future<void> Function() task)
      _runBackgroundTask;

  Future<DateTime> resolvePlaceholderBaseTime(String convId) async {
    final allMessages = await _ref
        .read(conversationShortWindowStoreProvider)
        .loadAllMessages(convId);
    final lastCreatedAt =
        allMessages.isNotEmpty ? allMessages.last.createdAt : DateTime.now();
    final now = DateTime.now();
    if (now.isAfter(lastCreatedAt)) return now;
    return lastCreatedAt.add(const Duration(milliseconds: 1));
  }

  Future<void> upsertPlaceholders({
    required String convId,
    required List<DeferredImageJob> jobs,
  }) async {
    for (final job in jobs) {
      await _upsertPlaceholder(
        convId: convId,
        messageId: job.messageId,
        createdAt: job.createdAt,
        sourceMessageId: job.sourceMessageId,
      );
    }
  }

  void scheduleJobs({
    required String convId,
    required List<DeferredImageJob> jobs,
  }) {
    for (final job in jobs) {
      _runBackgroundTask('deferred_image_${job.messageId}', () async {
        var keepMessageInTimeline = false;
        try {
          final imageResult = await _buildImageMessage(
            convId: convId,
            prompt: job.prompt,
            messageId: job.messageId,
          );
          if (imageResult.message != null) {
            final finalMessage = imageResult.message!.copyWith(
              createdAt: job.createdAt,
              sourceMessageId: job.sourceMessageId,
            );
            await _enqueueStoreMutation(() {
              return _ref.read(chatHistoryStoreProvider).updateMessage(
                    conversationId: convId,
                    message: finalMessage,
                    lastMessagePreview: finalMessage.displayText,
                  );
            });
            keepMessageInTimeline = true;
          } else if ((job.failureAnchorMessageId ?? '').trim().isNotEmpty &&
              imageResult.failurePayload != null) {
            await _attachHiddenImageContextToMessage(
              convId: convId,
              anchorMessageId: job.failureAnchorMessageId!,
              payload: imageResult.failurePayload!,
            );
          } else if (imageResult.failurePayload != null) {
            AppLogger.warning(
                'ChatDeferredImageDelivery', '失败图片缺少可挂载锚点，已跳过上下文回写',
                metadata: {
                  'convId': convId,
                  'messageId': job.messageId,
                  'promptLength': job.prompt.length,
                });
          }
        } finally {
          if (!keepMessageInTimeline) {
            await removePlaceholders(
              convId: convId,
              messageIds: [job.messageId],
            );
          }
        }
      });
    }
  }

  Future<void> removePlaceholders({
    required String convId,
    required Iterable<String> messageIds,
  }) async {
    final normalizedIds = <String>[
      for (final messageId in messageIds)
        if (messageId.trim().isNotEmpty) messageId.trim(),
    ];
    if (normalizedIds.isEmpty) return;
    await _enqueueStoreMutation(() {
      return _ref.read(chatHistoryStoreProvider).softDeleteMessages(
            convId,
            normalizedIds,
          );
    });
  }

  Future<void> _upsertPlaceholder({
    required String convId,
    required String messageId,
    required DateTime createdAt,
    String? sourceMessageId,
  }) async {
    final placeholder = Message.fromBlocks(
      id: messageId,
      role: 'assistant',
      sourceMessageId: sourceMessageId,
      blocks: [
        TextBlock(
          messageId: messageId,
          content: '生成中...',
          status: BlockStatus.streaming,
        ),
      ],
      createdAt: createdAt,
      status: 'sending',
    );
    await _enqueueStoreMutation(() {
      return _ref.read(chatHistoryStoreProvider).updateMessage(
            conversationId: convId,
            message: placeholder,
          );
    });
  }

  Future<_ImageBuildResult> _buildImageMessage({
    required String convId,
    required String prompt,
    required String messageId,
  }) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    final imagePlugin = pluginManager.getPlugin('image') as ImagePlugin?;
    if (imagePlugin == null || !imagePlugin.enabled) {
      return _ImageBuildResult.failure(
        ChatRequestMessageBuilder.buildImageContextPayload(
          role: 'assistant',
          status: 'failed',
          rawPrompt: prompt,
          reason: 'image_plugin_unavailable',
          imagePresent: false,
        ),
      );
    }

    _ref.read(chatStatusProvider.notifier).state = ChatStatus.generatingImage;
    final roleArtistPresetName =
        await _resolveConversationArtistPresetBinding(convId);
    final result = await imagePlugin.generateInlineImage(
      prompt: prompt,
      roleArtistPresetName: roleArtistPresetName,
    );
    if (!result.success ||
        result.localPath == null ||
        result.localPath!.isEmpty) {
      AppLogger.warning('ChatDeferredImageDelivery', '直连 <image> 生成失败，已记录隐藏上下文',
          metadata: {
            'convId': convId,
            'error': result.error,
            'promptLength': prompt.length,
          });
      return _ImageBuildResult.failure(
        ChatRequestMessageBuilder.buildImageContextPayload(
          role: 'assistant',
          status: 'failed',
          rawPrompt: result.rawPrompt ?? prompt,
          prompt: result.prompt,
          reason: result.error ?? 'inline_image_generation_failed',
          imagePresent: false,
        ),
      );
    }

    return _ImageBuildResult.success(
      Message.fromBlocks(
        id: messageId,
        role: 'assistant',
        blocks: [
          ImageBlock(
            messageId: messageId,
            localPath: result.localPath!,
            prompt: result.prompt ?? result.rawPrompt ?? prompt,
          ),
        ],
        createdAt: DateTime.now(),
        status: 'sent',
      ),
    );
  }

  Future<String?> _resolveConversationArtistPresetBinding(String convId) async {
    final normalizedConvId = convId.trim();
    if (normalizedConvId.isEmpty) return null;
    try {
      final conversation = await _ref
          .read(conversationRepositoryProvider)
          .getById(normalizedConvId);
      if (conversation == null) return null;
      final personaPrompt = conversation.personaPrompt.trim();
      if (personaPrompt.isEmpty) return null;
      final personaParts = PersonaPromptCodec.parse(personaPrompt);
      final value = personaParts.drawingArtistPresetName?.trim();
      if (value == null || value.isEmpty) {
        return null;
      }
      return value;
    } catch (e) {
      AppLogger.warning('ChatDeferredImageDelivery', '读取会话画师串绑定失败', metadata: {
        'convId': normalizedConvId,
        'error': e.toString(),
      });
      return null;
    }
  }

  Future<void> _attachHiddenImageContextToMessage({
    required String convId,
    required String anchorMessageId,
    required Map<String, dynamic> payload,
  }) async {
    final normalizedMessageId = anchorMessageId.trim();
    if (normalizedMessageId.isEmpty) return;
    final store = _ref.read(chatHistoryStoreProvider);
    final anchor = await store.loadFrontendMessageById(
      normalizedMessageId,
      conversationId: convId,
    );
    if (anchor == null) return;

    final existingBlocks = List<MessageBlock>.from(anchor.blocks ??
        <MessageBlock>[
          if (anchor.content.isNotEmpty)
            TextBlock(
              messageId: anchor.id,
              content: anchor.content,
            ),
        ]);
    existingBlocks.add(ToolBlock(
      messageId: anchor.id,
      toolName: ChatRequestMessageBuilder.internalImageContextToolName,
      result: payload,
    ));
    await _enqueueStoreMutation(() {
      return store.updateMessage(
        conversationId: convId,
        message: anchor.copyWith(
          content: '',
          blocks: existingBlocks,
        ),
        lastMessagePreview: anchor.displayText,
      );
    });
  }
}

class _ImageBuildResult {
  const _ImageBuildResult.success(this.message) : failurePayload = null;

  const _ImageBuildResult.failure(this.failurePayload) : message = null;

  final Message? message;
  final Map<String, dynamic>? failurePayload;
}
