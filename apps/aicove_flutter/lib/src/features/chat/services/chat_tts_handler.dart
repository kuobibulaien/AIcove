/// TTS 与多模态消息交付服务
///
/// 封装 TTS 语音消息的生成与交付逻辑，同时处理表情包等多模态内容的顺序交付。
///
/// 核心方法：`deliverSegmentedMessages()`
/// - 无多模态标签时：直接交付文本消息
/// - 有多模态标签时：按 <tts>/[表情包] 分段，文本直接发，语音生成完再发，表情包直接发
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
/// - 2026-01-14: 添加 TTS 失败回退机制
/// - 2026-01-28: 重写为顺序发送模式，移除占位符机制
/// - 2026-02-21: 统一多模态交付，支持表情包按位置顺序发送
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';
import '../id_gen.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import 'chat_message_processor.dart';
import 'chat_history_store.dart';
import 'chat_deferred_image_delivery.dart';
import 'chat_multimodal_delivery_planner.dart';
import 'chat_pending_tts_resolver.dart';
import 'chat_send_service.dart';
import 'chat_types.dart';
import 'tts_fallback_notification.dart';

// 重新导出 TTS 失败通知服务，方便外部使用
export 'tts_fallback_notification.dart'
    show
        TtsFallbackNotificationService,
        ttsFallbackNotificationServiceProvider,
        TtsFallbackNotificationListener;

/// TTS 失败回退通知回调类型
typedef TtsFallbackNotifier = void Function(String reason);

int resolveInsertSlotByChars({
  required List<int> textChunkLengths,
  required int textCharsBefore,
}) {
  if (textChunkLengths.isEmpty) return 0;
  if (textCharsBefore <= 0) return 0;

  var cumulative = 0;
  for (var i = 0; i < textChunkLengths.length; i++) {
    final len = textChunkLengths[i] < 0 ? 0 : textChunkLengths[i];
    cumulative += len;
    if (textCharsBefore <= cumulative) {
      return i + 1;
    }
  }
  return textChunkLengths.length;
}

int resolveSupplementInsertSlot({
  required List<int> textChunkLengths,
  required int textCharsBefore,
  bool forceAppendToTail = false,
}) {
  if (forceAppendToTail) {
    return textChunkLengths.length;
  }
  return resolveInsertSlotByChars(
    textChunkLengths: textChunkLengths,
    textCharsBefore: textCharsBefore,
  );
}

int _normalizedTextLength(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').length;

/// TTS 处理服务
///
/// 提供统一的消息交付入口，自动处理 TTS 语音段的顺序生成和发送。
class ChatTtsHandler {
  final Ref _ref;
  final TtsPlayerManager? _ttsManager;
  final ChatMultimodalDeliveryPlanner _deliveryPlanner =
      const ChatMultimodalDeliveryPlanner();
  Future<void> _storeMutationQueue = Future<void>.value();

  /// TTS 失败回退通知回调
  TtsFallbackNotifier? onTtsFallback;

  ChatTtsHandler(this._ref) : _ttsManager = _ref.read(ttsPlayerManagerProvider);

  late final ChatPendingTtsResolver _pendingTtsResolver =
      ChatPendingTtsResolver(
    ref: _ref,
    ttsManager: _ttsManager,
    enqueueStoreMutation: _enqueueStoreMutation,
    onTtsFallback: (reason) => onTtsFallback?.call(reason),
  );

  late final ChatDeferredImageDelivery _deferredImageDelivery =
      ChatDeferredImageDelivery(
    ref: _ref,
    enqueueStoreMutation: _enqueueStoreMutation,
    runBackgroundTask: _runBackgroundTask,
  );

  Future<void> _enqueueStoreMutation(Future<void> Function() action) {
    final future = _storeMutationQueue.catchError((_) {}).then((_) => action());
    _storeMutationQueue = future.catchError((_) {});
    return future;
  }

  void _runBackgroundTask(String label, Future<void> Function() task) {
    unawaited(() async {
      try {
        await task();
      } catch (e) {
        AppLogger.error('ChatTtsHandler', '后台多模态任务失败', metadata: {
          'label': label,
          'error': e.toString(),
        });
      }
    }());
  }

  /// 统一的消息交付入口
  ///
  /// 根据是否包含 TTS 标签，自动选择交付策略：
  /// - 无 TTS：直接交付所有消息
  /// - 有 TTS：按 <tts> 标签分段，文本直接发，语音生成完再发
  ///
  /// [convId] 会话 ID
  /// [userMsgId] 用户消息 ID（用于标记发送成功）
  /// [buildResult] 消息构建结果（只含文本消息，TTS 段在此方法内处理）
  /// [replyText] AI 原始回复文本（用于解析 TTS 标签）
  /// [pluginEvents] 插件事件列表
  /// [ttsEnabled] 是否启用 TTS
  Future<void> deliverSegmentedMessages({
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
    bool appendAfterStreamText = false,
    List<String>? streamTextMessageIds,
    List<Message>? streamPendingTtsMessages,
    TraceLogger? trace,
  }) async {
    final hasTtsEvents = pluginEvents.any((e) => e.type == 'tts_convert');
    final hasImageEvents = pluginEvents.any((e) => e.type == 'image_generate');

    // 检查是否有工具音频（路径 A：speak 工具产生的音频）
    final hasToolAudio = buildResult.messages.any(
      (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
    );
    final canGenerateTts =
        hasTtsEvents && ttsEnabled && _ttsManager != null && !hasToolAudio;

    if (appendAfterStreamText) {
      await _deliverPostStreamSupplements(
        convId: convId,
        userMsgId: userMsgId,
        buildResult: buildResult,
        replyText: replyText,
        pluginEvents: pluginEvents,
        canGenerateTts: canGenerateTts,
        hasImageEvents: hasImageEvents,
        streamTextMessageIds: streamTextMessageIds,
        streamPendingTtsMessages: streamPendingTtsMessages,
        trace: trace,
      );
      return;
    }

    // 没有需要后补的多模态内容 → 直接交付
    if (!canGenerateTts && !hasImageEvents) {
      await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
            convId: convId,
            userMsgId: userMsgId,
            messages: buildResult.messages,
            lastMessagePreview: buildResult.lastMessageText,
            trace: trace,
          );
      return;
    }

    // 有后补多模态标签 → 按段顺序发送（同时处理图片 / TTS / 表情包）
    await _deliverWithMultimodalSegments(
      convId: convId,
      userMsgId: userMsgId,
      replyText: replyText,
      pluginEvents: pluginEvents,
      canGenerateTts: canGenerateTts,
      trace: trace,
    );
  }

  /// 按多模态标签分段，顺序发送文本、语音和表情包消息
  ///
  /// 流程：
  /// 1. 解析 replyText 得到 [text, tts, text, sticker, text, ...] 片段
  /// 2. 遍历片段：
  ///    - text 段 → 直接添加为文本消息
  ///    - tts 段 → 调用 TtsPlayerManager 生成语音 → 成功则发语音消息，失败则发文本消息
  ///    - sticker 段 → 直接添加为表情包消息
  /// 3. 每发完一段就更新对话，用户实时看到消息
  Future<void> _deliverPostStreamSupplements({
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    required bool hasImageEvents,
    required List<String>? streamTextMessageIds,
    required List<Message>? streamPendingTtsMessages,
    TraceLogger? trace,
  }) async {
    final pendingStreamTts = streamPendingTtsMessages
            ?.where(ChatPendingTtsResolver.isPendingPlaceholder)
            .toList(growable: false) ??
        const <Message>[];

    final ids = streamTextMessageIds
            ?.where((id) => id.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    if (ids.isEmpty) {
      final supplements = _extractNonTextMessages(
        buildResult.messages,
        includeEmoji: pendingStreamTts.isNotEmpty ? true : !canGenerateTts,
      );
      await _deliverSupplementMessages(
        convId: convId,
        messages: supplements,
        trace: trace,
      );
      if (pendingStreamTts.isNotEmpty) {
        _schedulePendingStreamTtsResolution(
          convId: convId,
          messages: pendingStreamTts,
          trace: trace,
        );
      }
      if (canGenerateTts || hasImageEvents) {
        _runBackgroundTask('post_stream_no_anchor_supplements', () {
          return _deliverWithMultimodalSegments(
            convId: convId,
            userMsgId: userMsgId,
            replyText: replyText,
            pluginEvents: pluginEvents,
            canGenerateTts: canGenerateTts,
            skipTextSegments: true,
            markUserMessageAsSent: false,
            allowTtsTextFallback: true,
            trace: trace,
          );
        });
      }
      return;
    }

    final insertOps = <ChatSupplementInsertOp>[
      ..._collectBuildResultSupplementOps(
        buildResult.messages,
        includeEmoji: !canGenerateTts,
        startOrder: 0,
      ),
    ];

    if (insertOps.isNotEmpty) {
      _sortInsertOps(insertOps);
      await _insertSupplementsAroundStreamText(
        convId: convId,
        streamTextMessageIds: ids,
        insertOps: insertOps,
        trace: trace,
      );
    }

    if (canGenerateTts || hasImageEvents) {
      _scheduleDeferredStreamSupplements(
        convId: convId,
        replyText: replyText,
        pluginEvents: pluginEvents,
        canGenerateTts: canGenerateTts,
        streamTextMessageIds: ids,
        startOrder: insertOps.length,
        includeTts: pendingStreamTts.isEmpty,
        trace: trace,
      );
    }

    if (pendingStreamTts.isNotEmpty) {
      _schedulePendingStreamTtsResolution(
        convId: convId,
        messages: pendingStreamTts,
        trace: trace,
      );
    }
  }

  List<Message> _extractNonTextMessages(
    List<Message> messages, {
    bool includeEmoji = true,
  }) {
    final result = <Message>[];
    for (final message in messages) {
      final normalized = _toNonTextMessage(message, includeEmoji: includeEmoji);
      if (normalized != null) {
        result.add(normalized);
      }
    }
    return result;
  }

  Message? _toNonTextMessage(
    Message message, {
    required bool includeEmoji,
  }) {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      return null;
    }

    final nonTextBlocks = <MessageBlock>[];
    for (final block in blocks) {
      if (block is TextBlock) continue;
      if (!includeEmoji && block is EmojiBlock) continue;
      nonTextBlocks.add(block);
    }

    if (nonTextBlocks.isEmpty) {
      return null;
    }
    return message.copyWith(
      content: '',
      blocks: nonTextBlocks,
    );
  }

  Future<void> _deliverSupplementMessages({
    required String convId,
    required List<Message> messages,
    TraceLogger? trace,
  }) async {
    if (messages.isEmpty) return;
    await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
          convId: convId,
          userMsgId: '',
          messages: messages,
          lastMessagePreview: messages.last.displayText,
          trace: trace,
        );
  }

  void _scheduleDeferredStreamSupplements({
    required String convId,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    required List<String> streamTextMessageIds,
    required int startOrder,
    required bool includeTts,
    TraceLogger? trace,
  }) {
    _runBackgroundTask('post_stream_supplements', () async {
      final plan = _deliveryPlanner.planPostStreamSupplements(
        replyText: replyText,
        pluginEvents: pluginEvents,
        canGenerateTts: canGenerateTts,
        includeTts: includeTts,
        startOrder: startOrder,
        pendingTtsPlaceholderBuilder:
            _pendingTtsResolver.buildPendingPlaceholderMessage,
        stickerMessageBuilder: _buildStickerMessageFromSegment,
      );

      if (plan.insertOps.isNotEmpty) {
        _sortInsertOps(plan.insertOps);
        await _insertSupplementsAroundStreamText(
          convId: convId,
          streamTextMessageIds: streamTextMessageIds,
          insertOps: plan.insertOps,
          trace: trace,
        );
      }

      for (final pendingMessage in plan.pendingTtsMessages) {
        _scheduleSinglePendingTtsResolution(
          convId: convId,
          message: pendingMessage,
        );
      }

      if (plan.imagePrompts.isNotEmpty) {
        final imagePlaceholderBaseTime =
            await _deferredImageDelivery.resolvePlaceholderBaseTime(convId);
        final deferredImageJobs = <DeferredImageJob>[
          for (var i = 0; i < plan.imagePrompts.length; i++)
            DeferredImageJob(
              messageId: genId('img'),
              prompt: plan.imagePrompts[i],
              createdAt:
                  imagePlaceholderBaseTime.add(Duration(milliseconds: i + 1)),
              failureAnchorMessageId: streamTextMessageIds.isNotEmpty
                  ? streamTextMessageIds.last
                  : null,
            ),
        ];
        await _deferredImageDelivery.upsertPlaceholders(
          convId: convId,
          jobs: deferredImageJobs,
        );
        _deferredImageDelivery.scheduleJobs(
          convId: convId,
          jobs: deferredImageJobs,
        );
      }
    });
  }

  void _schedulePendingStreamTtsResolution({
    required String convId,
    required List<Message> messages,
    TraceLogger? trace,
  }) {
    _runBackgroundTask('pending_stream_tts', () async {
      await _pendingTtsResolver.resolvePendingMessages(
        convId: convId,
        messages: messages,
        trace: trace,
      );
    });
  }

  void _sortInsertOps(List<ChatSupplementInsertOp> insertOps) {
    _deliveryPlanner.sortInsertOps(insertOps);
  }

  List<ChatSupplementInsertOp> _collectBuildResultSupplementOps(
    List<Message> messages, {
    required bool includeEmoji,
    required int startOrder,
  }) {
    final ops = <ChatSupplementInsertOp>[];
    final hasTextAfter = List<bool>.filled(messages.length, false);
    var seenTextAfter = false;
    for (var i = messages.length - 1; i >= 0; i--) {
      hasTextAfter[i] = seenTextAfter;
      final text = _extractTextPart(messages[i]);
      if (text.trim().isNotEmpty) {
        seenTextAfter = true;
      }
    }
    var textChars = 0;
    var order = startOrder;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final textPart = _extractTextPart(message);
      if (textPart.trim().isNotEmpty) {
        textChars += _normalizedTextLength(textPart);
      }
      final nonText = _toNonTextMessage(message, includeEmoji: includeEmoji);
      if (nonText == null) continue;
      ops.add(ChatSupplementInsertOp(
        textCharsBefore: textChars,
        order: order++,
        message: nonText,
        forceAppendToTail: !hasTextAfter[i],
      ));
    }
    return ops;
  }

  Message? _buildStickerMessageFromSegment(MultimodalSegment segment) {
    final assetPath = segment.stickerData?['assetPath'] as String?;
    if (assetPath == null || assetPath.isEmpty) return null;
    final stickerId = segment.stickerData?['stickerId'] as String?;
    final tag = segment.stickerData?['tag'] as String?;
    final stickerMsgId = genId('sticker');
    return Message.fromBlocks(
      id: stickerMsgId,
      role: 'assistant',
      blocks: [
        EmojiBlock(
          messageId: genId('emoji'),
          emojiId: stickerId ?? tag ?? 'unknown',
          path: assetPath,
          matchedTag: tag,
        ),
      ],
      createdAt: DateTime.now(),
      status: 'sent',
    );
  }

  Message _buildPendingTtsPlaceholderMessage(
    String ttsText, {
    String? messageId,
    DateTime? createdAt,
  }) {
    return _pendingTtsResolver.buildPendingPlaceholderMessage(
      ttsText,
      messageId: messageId ?? genId('msg'),
      createdAt: createdAt,
    );
  }

  void _scheduleSinglePendingTtsResolution({
    required String convId,
    required Message message,
  }) {
    _runBackgroundTask('pending_tts_${message.id}', () async {
      await _pendingTtsResolver.resolveSinglePendingMessage(
        convId: convId,
        message: message,
      );
    });
  }

  String _extractTextPart(Message message) {
    final blocks = message.blocks;
    if (blocks != null && blocks.isNotEmpty) {
      final text =
          blocks.whereType<TextBlock>().map((block) => block.content).join();
      if (text.trim().isNotEmpty) {
        return text;
      }
    }
    return message.content;
  }

  Future<void> _insertSupplementsAroundStreamText({
    required String convId,
    required List<String> streamTextMessageIds,
    required List<ChatSupplementInsertOp> insertOps,
    TraceLogger? trace,
  }) async {
    if (insertOps.isEmpty) return;
    await _enqueueStoreMutation(() {
      return _ref.read(chatHistoryStoreProvider).insertMessagesAroundAnchor(
        conversationId: convId,
        anchorIds: streamTextMessageIds,
        insertOps: [
          for (final op in insertOps)
            ConversationSupplementInsertOp(
              textCharsBefore: op.textCharsBefore,
              message: op.message,
              forceAppendToTail: op.forceAppendToTail,
            ),
        ],
      );
    });
    trace?.note('后补多模态已按流式文本位置插入', metadata: {
      'convId': convId,
      'insertCount': insertOps.length,
    });
  }

  Future<void> _deliverWithMultimodalSegments({
    required String convId,
    required String userMsgId,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    bool skipTextSegments = false,
    bool markUserMessageAsSent = true,
    bool allowTtsTextFallback = true,
    TraceLogger? trace,
  }) async {
    final segments =
        chatMessageProcessor.parseMultimodalSegments(replyText, pluginEvents);

    if (segments.isEmpty) {
      if (skipTextSegments && !allowTtsTextFallback) {
        AppLogger.warning(
          'ChatTtsHandler',
          'TTS tags parsed empty, skip text fallback in post-stream mode',
        );
        return;
      }
      AppLogger.warning('ChatTtsHandler', 'TTS 标签解析结果为空，降级交付原始文本');
      final fallbackMsg = Message(
        id: genId('msg'),
        role: 'assistant',
        content: chatMessageProcessor.stripPluginTags(replyText),
        createdAt: DateTime.now(),
        status: 'sent',
      );
      await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
            convId: convId,
            userMsgId: userMsgId,
            messages: [fallbackMsg],
            lastMessagePreview: fallbackMsg.displayText,
            trace: trace,
          );
      return;
    }

    AppLogger.info('ChatTtsHandler', '开始多模态分段交付', metadata: {
      'convId': convId,
      'segmentCount': segments.length,
      'imageSegments':
          segments.where((s) => s.type == MultimodalSegmentType.image).length,
      'ttsSegments':
          segments.where((s) => s.type == MultimodalSegmentType.tts).length,
      'textSegments':
          segments.where((s) => s.type == MultimodalSegmentType.text).length,
      'stickerSegments':
          segments.where((s) => s.type == MultimodalSegmentType.sticker).length,
    });

    if (markUserMessageAsSent) {
      await _ref.read(chatHistoryStoreProvider).markMessageStatus(
            conversationId: convId,
            messageId: userMsgId,
            status: 'sent',
          );
    }

    final steps = _deliveryPlanner.planSequentialSteps(
      replyText: replyText,
      pluginEvents: pluginEvents,
      canGenerateTts: canGenerateTts,
      allowTtsTextFallback: allowTtsTextFallback,
      skipTextSegments: skipTextSegments,
      pendingTtsPlaceholderBuilder: _buildPendingTtsPlaceholderMessage,
      stickerMessageBuilder: _buildStickerMessageFromSegment,
    );

    String? lastTextAnchorMessageId;
    final deferredImageJobs = <DeferredImageJob>[];

    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final isLast = i == steps.length - 1;

      switch (step.type) {
        case ChatSequentialMultimodalStepType.text:
          final text = step.text?.trim() ?? '';
          if (text.isEmpty) continue;
          final textMsg = Message(
            id: genId('msg'),
            role: 'assistant',
            content: text,
            createdAt: DateTime.now(),
            status: 'sent',
          );
          await _appendMessageToConversation(
            convId: convId,
            message: textMsg,
            lastMessagePreview: isLast ? textMsg.displayText : null,
          );
          lastTextAnchorMessageId = textMsg.id;
          AppLogger.info('ChatTtsHandler', '已发送文本段', metadata: {
            'segmentIndex': i,
            'textLength': text.length,
          });
          break;
        case ChatSequentialMultimodalStepType.sticker:
          final stickerMsg = step.message?.copyWith(createdAt: DateTime.now());
          if (stickerMsg == null) continue;
          await _appendMessageToConversation(
            convId: convId,
            message: stickerMsg,
            lastMessagePreview: isLast ? stickerMsg.displayText : null,
          );
          AppLogger.info('ChatTtsHandler', '已发送表情包段', metadata: {
            'segmentIndex': i,
          });
          break;
        case ChatSequentialMultimodalStepType.pendingTts:
          final pendingMessage = step.message?.copyWith(
            createdAt: DateTime.now(),
          );
          if (pendingMessage == null) continue;
          await _appendMessageToConversation(
            convId: convId,
            message: pendingMessage,
            lastMessagePreview: isLast ? pendingMessage.displayText : null,
          );
          _scheduleSinglePendingTtsResolution(
            convId: convId,
            message: pendingMessage,
          );
          AppLogger.info('ChatTtsHandler', '已发送语音占位段', metadata: {
            'segmentIndex': i,
            'textLength': pendingMessage.displayText.length,
          });
          break;
        case ChatSequentialMultimodalStepType.deferredImage:
          final imagePrompt = step.imagePrompt?.trim() ?? '';
          if (imagePrompt.isEmpty) continue;
          deferredImageJobs.add(DeferredImageJob(
            messageId: genId('img'),
            prompt: imagePrompt,
            createdAt: DateTime.now(),
            failureAnchorMessageId: lastTextAnchorMessageId,
          ));
          break;
      }
    }

    if (deferredImageJobs.isNotEmpty) {
      final baseTime = await _deferredImageDelivery.resolvePlaceholderBaseTime(
        convId,
      );
      final scheduledJobs = <DeferredImageJob>[
        for (var i = 0; i < deferredImageJobs.length; i++)
          DeferredImageJob(
            messageId: deferredImageJobs[i].messageId,
            prompt: deferredImageJobs[i].prompt,
            createdAt: baseTime.add(Duration(milliseconds: i + 1)),
            failureAnchorMessageId:
                deferredImageJobs[i].failureAnchorMessageId ??
                    lastTextAnchorMessageId,
          ),
      ];
      await _deferredImageDelivery.upsertPlaceholders(
        convId: convId,
        jobs: scheduledJobs,
      );
      _deferredImageDelivery.scheduleJobs(
        convId: convId,
        jobs: scheduledJobs,
      );
    }

    AppLogger.info('ChatTtsHandler', '多模态分段交付完成', metadata: {
      'convId': convId,
      'totalSegments': steps.length,
      'deferredImageCount': deferredImageJobs.length,
    });
  }

  /// 追加一条消息到对话
  Future<void> _appendMessageToConversation({
    required String convId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    await _ref.read(chatHistoryStoreProvider).appendMessage(
          conversationId: convId,
          message: message,
          lastMessagePreview: lastMessagePreview,
        );
  }
}

/// Provider
final chatTtsHandlerProvider = Provider((ref) {
  final handler = ChatTtsHandler(ref);

  // 连接到全局通知服务
  try {
    final notificationService =
        ref.read(ttsFallbackNotificationServiceProvider);
    handler.onTtsFallback = notificationService.notify;
  } catch (_) {
    // 服务未初始化，忽略
  }

  return handler;
});
