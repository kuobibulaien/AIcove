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
import '../../plugins/image/image_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/models/message_block.dart';
import '../../../core/models/block_status.dart';
import '../../../core/app_logger.dart';
import '../chat_providers.dart' show chatStatusProvider, ChatStatus;
import '../conversation_timeline_providers.dart';
import '../domain/persona_prompt_codec.dart';
import 'chat_message_processor.dart';
import 'chat_history_store.dart';
import 'chat_request_message_builder.dart';
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

class _SupplementInsertOp {
  const _SupplementInsertOp({
    required this.textCharsBefore,
    required this.order,
    required this.message,
    this.forceAppendToTail = false,
  });

  final int textCharsBefore;
  final int order;
  final Message message;
  final bool forceAppendToTail;
}

class _DeferredImageHistoryRecord {
  const _DeferredImageHistoryRecord({
    required this.textCharsBefore,
    required this.payload,
  });

  final int textCharsBefore;
  final Map<String, dynamic> payload;
}

class _DeferredSupplementCollection {
  const _DeferredSupplementCollection({
    this.insertOps = const <_SupplementInsertOp>[],
    this.failedImageRecords = const <_DeferredImageHistoryRecord>[],
  });

  final List<_SupplementInsertOp> insertOps;
  final List<_DeferredImageHistoryRecord> failedImageRecords;
}

class _DeferredSupplementResolution {
  const _DeferredSupplementResolution({
    this.insertOp,
    this.failedImageRecord,
  });

  final _SupplementInsertOp? insertOp;
  final _DeferredImageHistoryRecord? failedImageRecord;
}

class _DeferredImagePlaceholder {
  const _DeferredImagePlaceholder({
    required this.messageId,
    required this.order,
  });

  final String messageId;
  final int order;
}

class _DeferredImageJob {
  const _DeferredImageJob({
    required this.messageId,
    required this.prompt,
    required this.createdAt,
    this.failureAnchorMessageId,
  });

  final String messageId;
  final String prompt;
  final DateTime createdAt;
  final String? failureAnchorMessageId;
}

class _ImageSupplementBuildResult {
  const _ImageSupplementBuildResult.success(this.message)
      : failurePayload = null;

  const _ImageSupplementBuildResult.failure(this.failurePayload)
      : message = null;

  final Message? message;
  final Map<String, dynamic>? failurePayload;
}

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
  Future<void> _storeMutationQueue = Future<void>.value();

  static const Duration _ttsTimeout = Duration(seconds: 30);
  static const Duration _deferredImageHandoffTimeout =
      Duration(milliseconds: 320);
  static const Duration _deferredImageHandoffSettleDelay =
      Duration(milliseconds: 32);

  /// TTS 失败回退通知回调
  TtsFallbackNotifier? onTtsFallback;

  ChatTtsHandler(this._ref) : _ttsManager = _ref.read(ttsPlayerManagerProvider);

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
        ttsEnabled: ttsEnabled,
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
    required bool ttsEnabled,
    required bool canGenerateTts,
    required bool hasImageEvents,
    required List<String>? streamTextMessageIds,
    required List<Message>? streamPendingTtsMessages,
    TraceLogger? trace,
  }) async {
    final pendingStreamTts = streamPendingTtsMessages
            ?.where(_isPendingStreamTtsMessage)
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

    final insertOps = <_SupplementInsertOp>[
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
      final immediateInsertOps = <_SupplementInsertOp>[];
      final pendingTtsMessages = <Message>[];
      final deferredImageJobs = <_DeferredImageJob>[];
      final segments =
          chatMessageProcessor.parseMultimodalSegments(replyText, pluginEvents);
      var textChars = 0;
      var imageSeq = 0;
      DateTime? imagePlaceholderBaseTime;

      for (final segment in segments) {
        if (segment.type == MultimodalSegmentType.text) {
          textChars += _normalizedTextLength(segment.content);
          continue;
        }

        if (segment.type == MultimodalSegmentType.sticker) {
          final stickerMessage = _buildStickerMessageFromSegment(segment);
          if (stickerMessage != null) {
            immediateInsertOps.add(_SupplementInsertOp(
              textCharsBefore: textChars,
              order: startOrder + immediateInsertOps.length,
              message: stickerMessage,
            ));
          }
          continue;
        }

        if (segment.type == MultimodalSegmentType.tts) {
          if (!includeTts || !canGenerateTts) continue;
          final ttsText = segment.content.trim();
          if (ttsText.isEmpty) continue;
          final pendingMessage = _buildPendingTtsPlaceholderMessage(ttsText);
          pendingTtsMessages.add(pendingMessage);
          immediateInsertOps.add(_SupplementInsertOp(
            textCharsBefore: textChars,
            order: startOrder + immediateInsertOps.length,
            message: pendingMessage,
          ));
          continue;
        }

        final imagePrompt = (segment.imageData?['prompt'] as String?)?.trim() ??
            segment.content.trim();
        if (imagePrompt.isEmpty) continue;
        imagePlaceholderBaseTime ??=
            await _resolveDeferredImagePlaceholderBaseTime(convId);
        deferredImageJobs.add(_DeferredImageJob(
          messageId: genId('img'),
          prompt: imagePrompt,
          createdAt: imagePlaceholderBaseTime!.add(
            Duration(milliseconds: imageSeq + 1),
          ),
          failureAnchorMessageId: streamTextMessageIds.isNotEmpty
              ? streamTextMessageIds.last
              : null,
        ));
        imageSeq += 1;
      }

      if (immediateInsertOps.isNotEmpty) {
        _sortInsertOps(immediateInsertOps);
        await _insertSupplementsAroundStreamText(
          convId: convId,
          streamTextMessageIds: streamTextMessageIds,
          insertOps: immediateInsertOps,
          trace: trace,
        );
      }

      for (final pendingMessage in pendingTtsMessages) {
        _scheduleSinglePendingTtsResolution(
          convId: convId,
          message: pendingMessage,
        );
      }

      if (deferredImageJobs.isNotEmpty) {
        await _upsertDeferredImagePlaceholders(
          convId: convId,
          jobs: deferredImageJobs,
        );
        _scheduleDeferredImageJobs(
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
      await _resolvePendingStreamTtsMessages(
        convId: convId,
        messages: messages,
        trace: trace,
      );
    });
  }

  void _sortInsertOps(List<_SupplementInsertOp> insertOps) {
    insertOps.sort((a, b) {
      final byChars = a.textCharsBefore.compareTo(b.textCharsBefore);
      if (byChars != 0) return byChars;
      return a.order.compareTo(b.order);
    });
  }

  List<_SupplementInsertOp> _collectBuildResultSupplementOps(
    List<Message> messages, {
    required bool includeEmoji,
    required int startOrder,
  }) {
    final ops = <_SupplementInsertOp>[];
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
      ops.add(_SupplementInsertOp(
        textCharsBefore: textChars,
        order: order++,
        message: nonText,
        forceAppendToTail: !hasTextAfter[i],
      ));
    }
    return ops;
  }

  Future<_DeferredSupplementCollection> _collectDeferredSupplementOps({
    required String convId,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool canGenerateTts,
    required int startOrder,
    bool includeTts = true,
    bool includeStickers = true,
    Future<void> Function(_DeferredImagePlaceholder placeholder)?
        onDeferredImagePlanned,
  }) async {
    final ops = <_SupplementInsertOp>[];
    final failedImageRecords = <_DeferredImageHistoryRecord>[];
    final resolutions = <Future<_DeferredSupplementResolution?>>[];
    var textChars = 0;
    var order = startOrder;
    final segments =
        chatMessageProcessor.parseMultimodalSegments(replyText, pluginEvents);
    for (final segment in segments) {
      if (segment.type == MultimodalSegmentType.text) {
        textChars += _normalizedTextLength(segment.content);
        continue;
      }
      if (segment.type == MultimodalSegmentType.sticker) {
        if (!includeStickers) continue;
        final stickerMessage = _buildStickerMessageFromSegment(segment);
        if (stickerMessage != null) {
          ops.add(_SupplementInsertOp(
            textCharsBefore: textChars,
            order: order++,
            message: stickerMessage,
          ));
        }
        continue;
      }
      if (segment.type == MultimodalSegmentType.tts) {
        if (!canGenerateTts || !includeTts) continue;
        final ttsText = segment.content.trim();
        if (ttsText.isEmpty) continue;
        final currentTextChars = textChars;
        final currentOrder = order++;
        resolutions.add(() async {
          final ttsMessage = await _buildTtsSupplementMessage(ttsText);
          if (ttsMessage == null) return null;
          return _DeferredSupplementResolution(
            insertOp: _SupplementInsertOp(
              textCharsBefore: currentTextChars,
              order: currentOrder,
              message: ttsMessage,
            ),
          );
        }());
        continue;
      }

      final imagePrompt = (segment.imageData?['prompt'] as String?)?.trim() ??
          segment.content.trim();
      if (imagePrompt.isEmpty) continue;
      final currentTextChars = textChars;
      final currentOrder = order++;
      final imageMessageId = genId('img');
      if (onDeferredImagePlanned != null) {
        await onDeferredImagePlanned(
          _DeferredImagePlaceholder(
            messageId: imageMessageId,
            order: currentOrder,
          ),
        );
      }
      resolutions.add(() async {
        final imageResult = await _buildImageSupplementMessage(
          convId: convId,
          prompt: imagePrompt,
          messageId: imageMessageId,
        );
        return _DeferredSupplementResolution(
          insertOp: imageResult.message == null
              ? null
              : _SupplementInsertOp(
                  textCharsBefore: currentTextChars,
                  order: currentOrder,
                  message: imageResult.message!,
                  forceAppendToTail: true,
                ),
          failedImageRecord: imageResult.failurePayload == null
              ? null
              : _DeferredImageHistoryRecord(
                  textCharsBefore: currentTextChars,
                  payload: imageResult.failurePayload!,
                ),
        );
      }());
    }

    final results = await Future.wait(resolutions);
    for (final result in results) {
      if (result?.insertOp != null) {
        ops.add(result!.insertOp!);
      }
      if (result?.failedImageRecord != null) {
        failedImageRecords.add(result!.failedImageRecord!);
      }
    }
    return _DeferredSupplementCollection(
      insertOps: ops,
      failedImageRecords: failedImageRecords,
    );
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

  Future<Message?> _buildTtsSupplementMessage(String ttsText) async {
    _ref.read(chatStatusProvider.notifier).state = ChatStatus.generatingVoice;
    try {
      final audioUrl = await _convertTtsText(ttsText);
      if (audioUrl != null && audioUrl.isNotEmpty) {
        final audioMsgId = genId('msg');
        return Message.fromBlocks(
          id: audioMsgId,
          role: 'assistant',
          blocks: [
            AudioBlock(
              messageId: audioMsgId,
              url: audioUrl,
              text: ttsText,
            ),
          ],
          createdAt: DateTime.now(),
          status: 'sent',
        );
      }
      AppLogger.warning('ChatTtsHandler', 'TTS 后补生成失败，回退文本补位', metadata: {
        'textLength': ttsText.length,
      });
      return Message(
        id: genId('msg'),
        role: 'assistant',
        content: ttsText,
        createdAt: DateTime.now(),
        status: 'sent',
      );
    } catch (e) {
      AppLogger.error('ChatTtsHandler', 'TTS 后补异常，回退文本补位', metadata: {
        'error': e.toString(),
        'textLength': ttsText.length,
      });
      onTtsFallback?.call('convert_error');
      return Message(
        id: genId('msg'),
        role: 'assistant',
        content: ttsText,
        createdAt: DateTime.now(),
        status: 'sent',
      );
    }
  }

  Future<_ImageSupplementBuildResult> _buildImageSupplementMessage({
    required String convId,
    required String prompt,
    String? messageId,
  }) async {
    final pluginManager = _ref.read(pluginManagerProvider);
    final imagePlugin = pluginManager.getPlugin('image') as ImagePlugin?;
    if (imagePlugin == null || !imagePlugin.enabled) {
      return _ImageSupplementBuildResult.failure(
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
      AppLogger.warning('ChatTtsHandler', '直连 <image> 生成失败，已记录隐藏上下文',
          metadata: {
            'convId': convId,
            'error': result.error,
            'promptLength': prompt.length,
          });
      return _ImageSupplementBuildResult.failure(
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

    final msgId = messageId ?? genId('img');
    return _ImageSupplementBuildResult.success(
      Message.fromBlocks(
        id: msgId,
        role: 'assistant',
        blocks: [
          ImageBlock(
            messageId: msgId,
            localPath: result.localPath!,
            prompt: result.prompt ?? result.rawPrompt ?? prompt,
          ),
        ],
        createdAt: DateTime.now(),
        status: 'sent',
      ),
    );
  }

  Future<DateTime> _resolveDeferredImagePlaceholderBaseTime(
      String convId) async {
    final allMessages =
        await _ref.read(chatHistoryStoreProvider).loadAllMessages(
              convId,
            );
    final lastCreatedAt =
        allMessages.isNotEmpty ? allMessages.last.createdAt : DateTime.now();
    final now = DateTime.now();
    if (now.isAfter(lastCreatedAt)) return now;
    return lastCreatedAt.add(const Duration(milliseconds: 1));
  }

  Future<void> _upsertDeferredImagePlaceholder({
    required String convId,
    required String messageId,
    required DateTime createdAt,
  }) async {
    final placeholder = Message.fromBlocks(
      id: messageId,
      role: 'assistant',
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
    _ref
        .read(conversationTransientTimelineProvider(convId).notifier)
        .upsertMessage(placeholder);
  }

  Future<void> _removeDeferredImagePlaceholders({
    required String convId,
    required Iterable<String> messageIds,
  }) async {
    final controller =
        _ref.read(conversationTransientTimelineProvider(convId).notifier);
    for (final messageId in messageIds) {
      if (messageId.trim().isEmpty) continue;
      controller.removeMessage(messageId);
    }
  }

  Future<bool> _waitForDeferredImageStableHandoff({
    required String convId,
    required String messageId,
  }) async {
    final normalizedId = messageId.trim();
    if (normalizedId.isEmpty) return false;
    try {
      await _ref
          .read(chatHistoryStoreProvider)
          .watchWindow(
            conversationId: convId,
            limit:
                kConversationInitialVisibleCount + kConversationVisiblePageSize,
          )
          .firstWhere(
            (window) =>
                window.messages.any((message) => message.id == normalizedId),
          )
          .timeout(_deferredImageHandoffTimeout);
      await Future<void>.delayed(_deferredImageHandoffSettleDelay);
      return true;
    } catch (_) {
      AppLogger.warning('ChatTtsHandler', '等待图片占位交接稳定消息超时，进入兜底清理', metadata: {
        'convId': convId,
        'messageId': normalizedId,
        'timeoutMs': _deferredImageHandoffTimeout.inMilliseconds,
      });
      return false;
    }
  }

  Message _buildPendingTtsPlaceholderMessage(
    String ttsText, {
    String? messageId,
    DateTime? createdAt,
  }) {
    final placeholderId = messageId ?? genId('msg');
    return Message.fromBlocks(
      id: placeholderId,
      role: 'assistant',
      blocks: [
        AudioBlock(
          messageId: placeholderId,
          url: '',
          text: ttsText,
          status: BlockStatus.pending,
        ),
      ],
      createdAt: createdAt ?? DateTime.now(),
      status: 'sending',
    );
  }

  void _scheduleSinglePendingTtsResolution({
    required String convId,
    required Message message,
  }) {
    _runBackgroundTask('pending_tts_${message.id}', () async {
      await _resolveSinglePendingStreamTtsMessage(
        convId: convId,
        message: message,
      );
    });
  }

  Future<void> _upsertDeferredImagePlaceholders({
    required String convId,
    required List<_DeferredImageJob> jobs,
  }) async {
    for (final job in jobs) {
      await _upsertDeferredImagePlaceholder(
        convId: convId,
        messageId: job.messageId,
        createdAt: job.createdAt,
      );
    }
  }

  void _scheduleDeferredImageJobs({
    required String convId,
    required List<_DeferredImageJob> jobs,
  }) {
    for (final job in jobs) {
      _runBackgroundTask('deferred_image_${job.messageId}', () async {
        try {
          final imageResult = await _buildImageSupplementMessage(
            convId: convId,
            prompt: job.prompt,
            messageId: job.messageId,
          );
          if (imageResult.message != null) {
            final finalMessage = imageResult.message!.copyWith(
              createdAt: job.createdAt,
            );
            await _enqueueStoreMutation(() {
              return _ref.read(chatHistoryStoreProvider).appendMessage(
                    conversationId: convId,
                    message: finalMessage,
                    lastMessagePreview: finalMessage.displayText,
                  );
            });
            await _waitForDeferredImageStableHandoff(
              convId: convId,
              messageId: finalMessage.id,
            );
          } else if ((job.failureAnchorMessageId ?? '').trim().isNotEmpty &&
              imageResult.failurePayload != null) {
            await _attachHiddenImageContextToMessage(
              convId: convId,
              anchorMessageId: job.failureAnchorMessageId!,
              payload: imageResult.failurePayload!,
            );
          } else if (imageResult.failurePayload != null) {
            AppLogger.warning('ChatTtsHandler', '失败图片缺少可挂载锚点，已跳过上下文回写',
                metadata: {
                  'convId': convId,
                  'messageId': job.messageId,
                  'promptLength': job.prompt.length,
                });
          }
        } finally {
          await _removeDeferredImagePlaceholders(
            convId: convId,
            messageIds: [job.messageId],
          );
        }
      });
    }
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
      AppLogger.warning('ChatTtsHandler', '读取会话画师串绑定失败', metadata: {
        'convId': normalizedConvId,
        'error': e.toString(),
      });
      return null;
    }
  }

  Future<void> _attachFailedImageContextsNearStreamText({
    required String convId,
    required List<String> streamTextMessageIds,
    required List<_DeferredImageHistoryRecord> records,
    TraceLogger? trace,
  }) async {
    if (streamTextMessageIds.isEmpty || records.isEmpty) {
      return;
    }

    final resolvedAnchorIds = <String>[];
    final textChunkLengths = <int>[];
    for (final id in streamTextMessageIds) {
      final message =
          await _ref.read(chatHistoryStoreProvider).loadMessageById(id);
      if (message == null) continue;
      resolvedAnchorIds.add(id);
      textChunkLengths.add(_normalizedTextLength(_extractTextPart(message)));
    }
    if (resolvedAnchorIds.isEmpty) return;

    for (final record in records) {
      final slot = resolveSupplementInsertSlot(
        textChunkLengths: textChunkLengths,
        textCharsBefore: record.textCharsBefore,
      );
      final anchorIndex =
          slot <= 0 ? 0 : (slot - 1).clamp(0, resolvedAnchorIds.length - 1);
      await _attachHiddenImageContextToMessage(
        convId: convId,
        anchorMessageId: resolvedAnchorIds[anchorIndex],
        payload: record.payload,
      );
    }
    trace?.note('失败图片上下文已挂回流式文本锚点', metadata: {
      'convId': convId,
      'count': records.length,
    });
  }

  Future<void> _attachHiddenImageContextToMessage({
    required String convId,
    required String anchorMessageId,
    required Map<String, dynamic> payload,
  }) async {
    final normalizedMessageId = anchorMessageId.trim();
    if (normalizedMessageId.isEmpty) return;
    final store = _ref.read(chatHistoryStoreProvider);
    final anchor = await store.loadMessageById(normalizedMessageId);
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

  bool _isPendingStreamTtsMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is AudioBlock &&
        (block.url.isEmpty || block.status == BlockStatus.pending) &&
        (block.text?.trim().isNotEmpty ?? false);
  }

  Future<void> _resolvePendingStreamTtsMessages({
    required String convId,
    required List<Message> messages,
    TraceLogger? trace,
  }) async {
    if (messages.isEmpty) return;
    await Future.wait([
      for (final message in messages)
        _resolveSinglePendingStreamTtsMessage(
          convId: convId,
          message: message,
        ),
    ]);
    trace?.note('流式 TTS 占位已原位更新', metadata: {
      'convId': convId,
      'count': messages.length,
    });
  }

  Future<void> _resolveSinglePendingStreamTtsMessage({
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
    try {
      final audioUrl = await _convertTtsText(ttsText);
      if (audioUrl != null && audioUrl.isNotEmpty) {
        await _enqueueStoreMutation(() {
          return _ref.read(chatHistoryStoreProvider).updateMessage(
                conversationId: convId,
                message: Message.fromBlocks(
                  id: message.id,
                  role: message.role,
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
              );
        });
        return;
      }
      AppLogger.warning('ChatTtsHandler', '流式 TTS 占位生成失败，回退文本补位', metadata: {
        'messageId': message.id,
        'textLength': ttsText.length,
      });
      await _enqueueStoreMutation(() {
        return _ref.read(chatHistoryStoreProvider).updateMessage(
              conversationId: convId,
              message: Message.text(
                id: message.id,
                role: message.role,
                content: ttsText,
                createdAt: message.createdAt,
                status: 'sent',
              ),
            );
      });
    } catch (e) {
      AppLogger.error('ChatTtsHandler', '流式 TTS 占位异常，回退文本补位', metadata: {
        'messageId': message.id,
        'error': e.toString(),
      });
      onTtsFallback?.call('convert_error');
      await _enqueueStoreMutation(() {
        return _ref.read(chatHistoryStoreProvider).updateMessage(
              conversationId: convId,
              message: Message.text(
                id: message.id,
                role: message.role,
                content: ttsText,
                createdAt: message.createdAt,
                status: 'sent',
              ),
            );
      });
    }
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
    required List<_SupplementInsertOp> insertOps,
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

    String? lastTextAnchorMessageId;
    final deferredImageJobs = <_DeferredImageJob>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      if (segment.type == MultimodalSegmentType.text) {
        if (skipTextSegments) {
          AppLogger.info('ChatTtsHandler', 'Post-stream mode skip text segment',
              metadata: {
                'segmentIndex': i,
                'textLength': segment.content.length,
              });
          continue;
        }
        final text = segment.content.trim();
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
        continue;
      }

      if (segment.type == MultimodalSegmentType.sticker) {
        final assetPath = segment.stickerData?['assetPath'] as String?;
        final stickerId = segment.stickerData?['stickerId'] as String?;
        final tag = segment.stickerData?['tag'] as String?;
        if (assetPath == null || assetPath.isEmpty) continue;
        final stickerMsgId = genId('sticker');
        final stickerMsg = Message.fromBlocks(
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
        await _appendMessageToConversation(
          convId: convId,
          message: stickerMsg,
          lastMessagePreview: isLast ? '[表情]' : null,
        );
        AppLogger.info('ChatTtsHandler', '已发送表情包段', metadata: {
          'segmentIndex': i,
          'tag': tag,
        });
        continue;
      }

      if (segment.type == MultimodalSegmentType.image) {
        final imagePrompt = (segment.imageData?['prompt'] as String?)?.trim() ??
            segment.content.trim();
        if (imagePrompt.isEmpty) continue;
        deferredImageJobs.add(_DeferredImageJob(
          messageId: genId('img'),
          prompt: imagePrompt,
          createdAt: DateTime.now(),
          failureAnchorMessageId: lastTextAnchorMessageId,
        ));
        continue;
      }

      final ttsText = segment.content.trim();
      if (ttsText.isEmpty) continue;
      if (!canGenerateTts) {
        if (allowTtsTextFallback && !skipTextSegments) {
          final fallbackMsg = await _sendFallbackText(
            convId,
            ttsText,
            isLast,
            i,
          );
          lastTextAnchorMessageId = fallbackMsg.id;
        }
        continue;
      }

      final pendingMessage = _buildPendingTtsPlaceholderMessage(ttsText);
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
        'textLength': ttsText.length,
      });
    }

    if (deferredImageJobs.isNotEmpty) {
      final baseTime = await _resolveDeferredImagePlaceholderBaseTime(convId);
      final scheduledJobs = <_DeferredImageJob>[
        for (var i = 0; i < deferredImageJobs.length; i++)
          _DeferredImageJob(
            messageId: deferredImageJobs[i].messageId,
            prompt: deferredImageJobs[i].prompt,
            createdAt: baseTime.add(Duration(milliseconds: i + 1)),
            failureAnchorMessageId:
                deferredImageJobs[i].failureAnchorMessageId ??
                    lastTextAnchorMessageId,
          ),
      ];
      await _upsertDeferredImagePlaceholders(
        convId: convId,
        jobs: scheduledJobs,
      );
      _scheduleDeferredImageJobs(
        convId: convId,
        jobs: scheduledJobs,
      );
    }

    AppLogger.info('ChatTtsHandler', '多模态分段交付完成', metadata: {
      'convId': convId,
      'totalSegments': segments.length,
      'deferredImageCount': deferredImageJobs.length,
    });
  }

  /// 调用 TTS 服务生成语音
  ///
  /// 通过 TtsPlayerManager 生成，利用其已有的队列机制和 TtsService 配置
  Future<String?> _convertTtsText(String text) async {
    final manager = _ttsManager;
    if (manager == null) return null;

    // 创建一个一次性的 TTS 事件，通过 TtsPlayerManager 生成
    final eventId = genId('tts');
    final event = PluginEvent(
      pluginId: 'tts',
      type: 'tts_convert',
      data: {
        'text': text,
        'originalText': text,
      },
      id: eventId,
    );

    // 使用 Completer 等待生成结果
    final completer = Completer<String?>();

    // 监听 processedStream，等待我们的事件完成
    late final StreamSubscription<TtsPlayItem> sub;
    sub = manager.processedStream.listen((item) {
      if (item.event.id == eventId) {
        sub.cancel();
        if (item.status == TtsPlayItemStatus.completed &&
            item.audioUrl != null &&
            item.audioUrl!.isNotEmpty) {
          completer.complete(item.audioUrl);
        } else {
          completer.complete(null);
        }
      }
    });

    // 超时保护
    final timeout = Timer(_ttsTimeout, () {
      if (!completer.isCompleted) {
        sub.cancel();
        completer.complete(null);
        AppLogger.warning('ChatTtsHandler', 'TTS 生成超时', metadata: {
          'eventId': eventId,
          'textLength': text.length,
        });
      }
    });

    // 提交事件到队列
    await manager.addEvents([event]);

    final result = await completer.future;
    timeout.cancel();
    return result;
  }

  /// TTS 失败时发送回退文本消息
  Future<Message> _sendFallbackText(
      String convId, String text, bool isLast, int segmentIndex) async {
    final fallbackMsg = Message(
      id: genId('msg'),
      role: 'assistant',
      content: text,
      createdAt: DateTime.now(),
      status: 'sent',
    );

    await _appendMessageToConversation(
      convId: convId,
      message: fallbackMsg,
      lastMessagePreview: isLast ? text : null,
    );

    AppLogger.info('ChatTtsHandler', 'TTS 回退为文本消息', metadata: {
      'segmentIndex': segmentIndex,
      'textLength': text.length,
    });
    return fallbackMsg;
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
