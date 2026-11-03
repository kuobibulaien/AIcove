library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_providers.dart'
    show beginConversationImageTask, endConversationImageTask;
import '../domain/message.dart';
import '../../plugins/image/drawing_preset_provider.dart';
import '../../plugins/image/image_config.dart';
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/models/message_block.dart';
import '../../../core/models/block_status.dart';
import 'chat_history_store.dart';
import 'chat_request_message_builder.dart';
import 'conversation_short_window_store.dart';
import 'tts_fallback_notification.dart';

class DeferredImageJob {
  const DeferredImageJob({
    required this.messageId,
    required this.prompt,
    required this.createdAt,
    this.sourceMessageId,
    this.failureAnchorMessageId,
    this.hasPlaceholder = false,
  });

  final String messageId;
  final String prompt;
  final DateTime createdAt;
  final String? sourceMessageId;
  final String? failureAnchorMessageId;
  final bool hasPlaceholder;
}

class ChatDeferredImageDelivery {
  ChatDeferredImageDelivery({
    required Ref ref,
    required Future<void> Function(Future<void> Function())
    enqueueStoreMutation,
    required void Function(String label, Future<void> Function() task)
    runBackgroundTask,
    // Preserve public named parameters while keeping fields private.
    // ignore: prefer_initializing_formals
  }) : _ref = ref,
       // Preserve public named parameters while keeping fields private.
       // ignore: prefer_initializing_formals
       _enqueueStoreMutation = enqueueStoreMutation,
       // Preserve public named parameters while keeping fields private.
       // ignore: prefer_initializing_formals
       _runBackgroundTask = runBackgroundTask;

  final Ref _ref;
  final Future<void> Function(Future<void> Function()) _enqueueStoreMutation;
  final void Function(String label, Future<void> Function() task)
  _runBackgroundTask;

  Message buildPendingPlaceholderMessage({
    required String messageId,
    required String prompt,
    required DateTime createdAt,
    String? sourceMessageId,
    int? width,
    int? height,
    Map<String, dynamic>? drawingSnapshot,
  }) {
    final plugin =
        _ref.read(pluginManagerProvider).getPlugin('image') as ImagePlugin?;
    final dimensions = plugin?.resolveInlineImageTargetDimensions(
      prompt: prompt,
      drawingSnapshot: drawingSnapshot,
    );
    final snapshotPlugin = plugin == null
        ? null
        : drawingSnapshot == null
        ? plugin
        : ImagePlugin(
            ImageConfig.fromJson(drawingSnapshot),
            _ref,
            isRequestSnapshot: true,
            postProcessor: drawingSnapshot['postProcessor'] as String?,
            requestSettings: plugin.requestSettings,
          );
    final generationSnapshot = snapshotPlugin?.buildPendingSnapshot(prompt: prompt);
    const defaults = ImageConfig();
    return Message.fromBlocks(
      id: messageId,
      role: 'assistant',
      status: 'sent',
      createdAt: createdAt,
      sourceMessageId: sourceMessageId,
      blocks: [
        ImageBlock(
          id: '${messageId}__b0_image',
          messageId: messageId,
          prompt: prompt,
          width: width ?? dimensions?.width ?? defaults.defaultWidth,
          height: height ?? dimensions?.height ?? defaults.defaultHeight,
          generationSnapshot: generationSnapshot,
          status: BlockStatus.pending,
        ),
      ],
    );
  }

  ImageBlock _withGenerationState(
    ImageBlock block, {
    required String prompt,
    required ImageGenerationSnapshot? snapshot,
    required BlockStatus status,
  }) => ImageBlock(
    id: block.id,
    messageId: block.messageId,
    createdAt: block.createdAt,
    url: block.url,
    localPath: block.localPath,
    base64: block.base64,
    width: block.width,
    height: block.height,
    versions: block.versions,
    activeVersionIndex: block.activeVersionIndex,
    prompt: prompt,
    generationSnapshot: snapshot,
    status: status,
  );

  Future<void> _removePendingPlaceholder(
    String convId,
    DeferredImageJob job,
  ) async {
    final timeline = _ref.read(conversationTimelineCacheProvider);
    final messages = await timeline.loadCachedMessages(convId);
    if (messages.any(
      (message) =>
          message.id == job.messageId &&
          message.blocks?.any(
                (block) =>
                    block is ImageBlock && block.status == BlockStatus.pending,
              ) ==
              true,
    )) {
      await timeline.replaceMessagesTransient(
        conversationId: convId,
        removeMessageIds: [job.messageId],
      );
    }
  }

  Future<DateTime> resolvePlaceholderBaseTime(String convId) async {
    final allMessages = await _ref
        .read(conversationTimelineCacheProvider)
        .loadCachedMessages(convId);
    final lastCreatedAt = allMessages.isNotEmpty
        ? allMessages.last.createdAt
        : DateTime.now();
    final now = DateTime.now();
    if (now.isAfter(lastCreatedAt)) return now;
    return lastCreatedAt.add(const Duration(milliseconds: 1));
  }

  /// Prepares an image for an atomic snapshot without touching the timeline.
  Future<Message> prepareSnapshotImage({
    required String convId,
    required String prompt,
    required String messageId,
    Map<String, dynamic>? drawingSnapshot,
  }) async {
    final result = await _buildImageMessage(
      convId: convId,
      prompt: prompt,
      messageId: messageId,
      drawingSnapshot: drawingSnapshot,
    );
    if (result.message == null) {
      throw StateError('Background image preparation failed');
    }
    return result.message!;
  }

  void scheduleJobs({
    required String convId,
    required List<DeferredImageJob> jobs,
    Map<String, dynamic>? drawingSnapshot,
    FutureOr<bool> Function()? shouldCommit,
  }) {
    final notificationTurnId = Object();
    for (final job in jobs) {
      _runBackgroundTask('deferred_image_${job.messageId}', () async {
        final imageResult = await _buildImageMessage(
          convId: convId,
          prompt: job.prompt,
          messageId: job.messageId,
          drawingSnapshot: drawingSnapshot,
        );
        if (imageResult.message != null) {
          await _enqueueStoreMutation(() async {
            if (shouldCommit != null && !await shouldCommit()) {
              await _removePendingPlaceholder(convId, job);
              return;
            }
            final messages = await _ref
                .read(conversationTimelineCacheProvider)
                .loadCachedMessages(convId);
            final existing = messages
                .where((message) => message.id == job.messageId)
                .firstOrNull;
            if (job.hasPlaceholder &&
                (existing == null ||
                    existing.blocks?.any(
                          (block) =>
                              block is ImageBlock &&
                              block.status == BlockStatus.pending,
                        ) !=
                        true)) {
              return;
            }
            var finalMessage = imageResult.message!.copyWith(
              createdAt: existing?.createdAt ?? job.createdAt,
              sourceMessageId: existing?.sourceMessageId ?? job.sourceMessageId,
            );
            final images = finalMessage.blocks!
                .whereType<ImageBlock>()
                .toList();
            final pending = existing?.blocks
                ?.whereType<ImageBlock>()
                .firstOrNull;
            if (images.length == 1 && pending != null) {
              final image = images.single;
              finalMessage = finalMessage.copyWith(
                blocks: [
                  ImageBlock(
                    id: pending.id,
                    messageId: finalMessage.id,
                    localPath: image.localPath,
                    width: image.width,
                    height: image.height,
                    prompt: image.prompt,
                    generationSnapshot: image.generationSnapshot,
                  ),
                ],
              );
            }
            final store = _ref.read(chatHistoryStoreProvider);
            if (existing != null) {
              await store.updateMessage(
                conversationId: convId,
                shouldCommit: shouldCommit,
                message: finalMessage,
                lastMessagePreview: finalMessage.displayText,
              );
            } else {
              await store.appendMessage(
                conversationId: convId,
                shouldCommit: shouldCommit,
                message: finalMessage,
                lastMessagePreview: finalMessage.displayText,
              );
            }
          });
          return;
        }
        await _enqueueStoreMutation(() async {
          if (shouldCommit != null && !await shouldCommit()) {
            await _removePendingPlaceholder(convId, job);
            return;
          }
          if (!job.hasPlaceholder) {
            await _removePendingPlaceholder(convId, job);
            return;
          }
          final messages = await _ref
              .read(conversationTimelineCacheProvider)
              .loadCachedMessages(convId);
          final existing = messages
              .where((message) => message.id == job.messageId)
              .firstOrNull;
          if (existing == null) return;
          var changed = false;
          final blocks = <MessageBlock>[
            for (final block in existing.blocks ?? <MessageBlock>[])
              if (block is ImageBlock && block.status == BlockStatus.pending)
                () {
                  changed = true;
                  return _withGenerationState(
                    block,
                    status: BlockStatus.error,
                    prompt: imageResult.generationSnapshot?.prompt ?? block.prompt ?? job.prompt,
                    snapshot:
                        imageResult.generationSnapshot ??
                        block.generationSnapshot,
                  );
                }()
              else
                block,
          ];
          if (!changed) return;
          await _ref
              .read(chatHistoryStoreProvider)
              .updateMessage(
                conversationId: convId,
                shouldCommit: shouldCommit,
                message: existing.copyWith(blocks: blocks),
                lastMessagePreview: existing.displayText,
              );
        });
        if (shouldCommit != null && !await shouldCommit()) return;
        _ref
            .read(ttsFallbackNotificationServiceProvider)
            .notifyImageFailure(
              conversationId: convId,
              turnId: notificationTurnId,
            );
        if (imageResult.failurePayload != null) {
          await _attachHiddenImageContextToMessage(
            convId: convId,
            anchorMessageId: job.failureAnchorMessageId,
            sourceMessageId: job.sourceMessageId,
            shouldCommit: shouldCommit,
            payload: imageResult.failurePayload!,
          );
        }
      });
    }
  }

  Future<_ImageBuildResult> _buildImageMessage({
    required String convId,
    required String prompt,
    required String messageId,
    Map<String, dynamic>? drawingSnapshot,
  }) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    var imagePlugin = pluginManager.getPlugin('image') as ImagePlugin?;
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

    beginConversationImageTask(_ref, convId);
    try {
      try {
        final ImageConfig config;
        if (drawingSnapshot != null) {
          config = ImageConfig.fromJson(drawingSnapshot);
        } else {
          final conversation = await _ref
              .read(conversationRepositoryProvider)
              .getById(convId);
          if (conversation == null) throw StateError('绘图所属角色不存在');
          config =
              (await _ref
                      .read(drawingPresetCatalogProvider.notifier)
                      .resolveForPersona(conversation.personaPrompt))
                  .config;
        }
        imagePlugin = ImagePlugin(config, _ref, isRequestSnapshot: true, postProcessor: drawingSnapshot?['postProcessor'] as String?);
      } catch (e) {
        return _ImageBuildResult.failure(
          ChatRequestMessageBuilder.buildImageContextPayload(
            role: 'assistant',
            status: 'failed',
            rawPrompt: prompt,
            reason: e.toString(),
            imagePresent: false,
          ),
        );
      }
      final result = await imagePlugin.generateInlineImage(prompt: prompt);
      if (!result.success ||
          result.localPath == null ||
          result.localPath!.isEmpty) {
        AppLogger.warning(
          'ChatDeferredImageDelivery',
          '直连 <image> 生成失败，已记录隐藏上下文',
          metadata: {
            'convId': convId,
            'error': result.error,
            'promptLength': prompt.length,
          },
        );
        return _ImageBuildResult.failure(
          ChatRequestMessageBuilder.buildImageContextPayload(
            role: 'assistant',
            status: 'failed',
            rawPrompt: result.rawPrompt ?? prompt,
            prompt: result.prompt,
            reason: result.error ?? 'inline_image_generation_failed',
            imagePresent: false,
          ),
          generationSnapshot: result.generationSnapshot,
        );
      }

      final imageFiles = result.images.isNotEmpty
          ? result.images
          : [
              for (final path
                  in result.localPaths.isEmpty
                      ? [result.localPath!]
                      : result.localPaths)
                GeneratedImageFile(
                  path,
                  width: result.width,
                  height: result.height,
                ),
            ];
      return _ImageBuildResult.success(
        Message.fromBlocks(
          id: messageId,
          role: 'assistant',
          blocks: [
            for (final (index, image) in imageFiles.indexed)
              ImageBlock(
                messageId: messageId,
                id: '${messageId}__b${index}_image',
                localPath: image.localPath,
                width: image.width,
                height: image.height,
                prompt: result.prompt ?? result.rawPrompt ?? prompt,
                generationSnapshot: result.generationSnapshot,
              ),
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        ),
      );
    } finally {
      endConversationImageTask(_ref, convId);
    }
  }

  Future<void> _attachHiddenImageContextToMessage({
    required String convId,
    required String? anchorMessageId,
    required String? sourceMessageId,
    required Map<String, dynamic> payload,
    FutureOr<bool> Function()? shouldCommit,
  }) {
    return _enqueueStoreMutation(() async {
      if (shouldCommit != null && !await shouldCommit()) return;
      final messages = await _ref
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(convId);
      final normalizedMessageId = anchorMessageId?.trim();
      final source = sourceMessageId?.trim();
      bool hasText(Message message) =>
          message.role == 'assistant' &&
          (message.blocks?.isNotEmpty == true
              ? message.blocks!.whereType<TextBlock>().any(
                  (block) => block.content.trim().isNotEmpty,
                )
              : message.content.trim().isNotEmpty);
      bool sameTurn(Message message) =>
          source != null &&
          source.isNotEmpty &&
          (message.sourceMessageId == source || message.id == source);
      final anchor =
          messages
              .where(
                (message) =>
                    message.id == normalizedMessageId &&
                    hasText(message) &&
                    (source == null || source.isEmpty || sameTurn(message)),
              )
              .firstOrNull ??
          messages.reversed
              .where((message) => hasText(message) && sameTurn(message))
              .firstOrNull;
      if (anchor == null) {
        AppLogger.warning(
          'ChatDeferredImageDelivery',
          '失败图片缺少可挂载锚点，已跳过上下文回写',
          metadata: {'convId': convId},
        );
        return;
      }
      final existingBlocks = List<MessageBlock>.from(
        anchor.blocks?.isNotEmpty == true
            ? anchor.blocks!
            : <MessageBlock>[
                if (anchor.content.isNotEmpty)
                  TextBlock(messageId: anchor.id, content: anchor.content),
              ],
      );
      existingBlocks.add(
        ToolBlock(
          messageId: anchor.id,
          toolName: ChatRequestMessageBuilder.internalImageContextToolName,
          result: payload,
        ),
      );
      await _ref
          .read(chatHistoryStoreProvider)
          .updateMessage(
            conversationId: convId,
            shouldCommit: shouldCommit,
            message: anchor.copyWith(content: '', blocks: existingBlocks),
            lastMessagePreview: anchor.displayText,
          );
    });
  }
}

class _ImageBuildResult {
  const _ImageBuildResult.success(this.message)
    : failurePayload = null,
      generationSnapshot = null;

  const _ImageBuildResult.failure(
    this.failurePayload, {
    this.generationSnapshot,
  }) : message = null;

  final Message? message;
  final Map<String, dynamic>? failurePayload;
  final ImageGenerationSnapshot? generationSnapshot;
}
