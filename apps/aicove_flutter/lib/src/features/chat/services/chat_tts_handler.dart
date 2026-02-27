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
import '../conversation_providers.dart';
import '../../plugins/domain/plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../plugins/tts/tts_player_manager.dart';
import '../../../core/models/message_block.dart';
import '../../../core/app_logger.dart';
import '../chat_providers.dart' show chatStatusProvider, ChatStatus;
import 'chat_message_processor.dart';
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

  static const Duration _ttsTimeout = Duration(seconds: 30);

  /// TTS 失败回退通知回调
  TtsFallbackNotifier? onTtsFallback;

  ChatTtsHandler(this._ref) : _ttsManager = _ref.read(ttsPlayerManagerProvider);

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
    TraceLogger? trace,
  }) async {
    final hasTtsEvents = pluginEvents.any((e) => e.type == 'tts_convert');

    // 检查是否有工具音频（路径 A：speak 工具产生的音频）
    final hasToolAudio = buildResult.messages.any(
      (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
    );

    if (appendAfterStreamText) {
      await _deliverPostStreamSupplements(
        convId: convId,
        userMsgId: userMsgId,
        buildResult: buildResult,
        replyText: replyText,
        pluginEvents: pluginEvents,
        ttsEnabled: ttsEnabled,
        hasTtsEvents: hasTtsEvents,
        hasToolAudio: hasToolAudio,
        streamTextMessageIds: streamTextMessageIds,
        trace: trace,
      );
      return;
    }

    // 无 TTS 或 TTS 未启用 或 已有工具音频 → 直接交付
    if (!hasTtsEvents || !ttsEnabled || _ttsManager == null || hasToolAudio) {
      await _ref.read(chatSendServiceProvider).deliverAssistantMessages(
            convId: convId,
            userMsgId: userMsgId,
            messages: buildResult.messages,
            lastMessagePreview: buildResult.lastMessageText,
            trace: trace,
          );
      return;
    }

    // 有 TTS 标签 → 按段顺序发送（同时处理表情包等多模态内容）
    await _deliverWithTtsSegments(
      convId: convId,
      userMsgId: userMsgId,
      replyText: replyText,
      pluginEvents: pluginEvents,
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
    required bool hasTtsEvents,
    required bool hasToolAudio,
    required List<String>? streamTextMessageIds,
    TraceLogger? trace,
  }) async {
    final canGenerateTts =
        hasTtsEvents && ttsEnabled && _ttsManager != null && !hasToolAudio;

    final ids = streamTextMessageIds
            ?.where((id) => id.trim().isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    if (ids.isEmpty) {
      // 未提供流式文本锚点，回退到旧逻辑（仅追加补充消息）。
      if (canGenerateTts) {
        final supplements = _extractNonTextMessages(
          buildResult.messages,
          includeEmoji: false,
        );
        await _deliverSupplementMessages(
          convId: convId,
          messages: supplements,
          trace: trace,
        );
        await _deliverWithTtsSegments(
          convId: convId,
          userMsgId: userMsgId,
          replyText: replyText,
          pluginEvents: pluginEvents,
          skipTextSegments: true,
          markUserMessageAsSent: false,
          allowTtsTextFallback: true,
          trace: trace,
        );
        return;
      }

      final supplements = _extractNonTextMessages(buildResult.messages);
      await _deliverSupplementMessages(
        convId: convId,
        messages: supplements,
        trace: trace,
      );
      return;
    }

    final insertOps = <_SupplementInsertOp>[
      ..._collectBuildResultSupplementOps(
        buildResult.messages,
        includeEmoji: !canGenerateTts,
        startOrder: 0,
      ),
    ];

    if (canGenerateTts) {
      final ttsOps = await _collectTtsAndStickerSupplementOps(
        replyText: replyText,
        pluginEvents: pluginEvents,
        startOrder: insertOps.length,
      );
      insertOps.addAll(ttsOps);
    }

    insertOps.sort((a, b) {
      final byChars = a.textCharsBefore.compareTo(b.textCharsBefore);
      if (byChars != 0) return byChars;
      return a.order.compareTo(b.order);
    });

    await _insertSupplementsAroundStreamText(
      convId: convId,
      streamTextMessageIds: ids,
      insertOps: insertOps,
      trace: trace,
    );
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

  Future<List<_SupplementInsertOp>> _collectTtsAndStickerSupplementOps({
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required int startOrder,
  }) async {
    final ops = <_SupplementInsertOp>[];
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
      final ttsText = segment.content.trim();
      if (ttsText.isEmpty) continue;
      final ttsMessage = await _buildTtsSupplementMessage(ttsText);
      if (ttsMessage != null) {
        ops.add(_SupplementInsertOp(
          textCharsBefore: textChars,
          order: order++,
          message: ttsMessage,
        ));
      }
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

    await _ref.read(conversationsProvider.notifier).updateOne(
      convId,
      (c) {
        final now = DateTime.now();
        final messageById = <String, Message>{
          for (final message in c.messages) message.id: message,
        };
        final existingStreamIds = <String>[
          for (final id in streamTextMessageIds)
            if (messageById.containsKey(id)) id,
        ];

        if (existingStreamIds.isEmpty) {
          final merged = <Message>[
            ...c.messages,
            ...insertOps.map((op) => op.message),
          ];
          final last = merged.isNotEmpty ? merged.last : null;
          return c.copyWith(
            messages: merged,
            updatedAt: now,
            lastMessage: last?.displayText ?? c.lastMessage,
            lastMessageTime: now,
          );
        }

        final textChunkLengths = <int>[
          for (final id in existingStreamIds)
            _normalizedTextLength(_extractTextPart(messageById[id]!)),
        ];
        final slotMessages = <int, List<Message>>{};
        for (final op in insertOps) {
          final slot = resolveSupplementInsertSlot(
            textChunkLengths: textChunkLengths,
            textCharsBefore: op.textCharsBefore,
            forceAppendToTail: op.forceAppendToTail,
          );
          (slotMessages[slot] ??= <Message>[]).add(op.message);
        }

        final streamOrderById = <String, int>{
          for (var i = 0; i < existingStreamIds.length; i++)
            existingStreamIds[i]: i,
        };
        final rebuilt = <Message>[];
        final firstStreamId = existingStreamIds.first;
        var insertedBeforeFirstStream = false;
        for (final message in c.messages) {
          if (!insertedBeforeFirstStream && message.id == firstStreamId) {
            rebuilt.addAll(slotMessages[0] ?? const <Message>[]);
            insertedBeforeFirstStream = true;
          }
          rebuilt.add(message);
          final order = streamOrderById[message.id];
          if (order == null) continue;
          final slot = order + 1;
          final inserts = slotMessages[slot];
          if (inserts != null && inserts.isNotEmpty) {
            rebuilt.addAll(inserts);
          }
        }

        final last = rebuilt.isNotEmpty ? rebuilt.last : null;
        return c.copyWith(
          messages: rebuilt,
          updatedAt: now,
          lastMessage: last?.displayText ?? c.lastMessage,
          lastMessageTime: now,
        );
      },
    );
    trace?.note('后补多模态已按流式文本位置插入', metadata: {
      'convId': convId,
      'insertCount': insertOps.length,
    });
  }

  Future<void> _deliverWithTtsSegments({
    required String convId,
    required String userMsgId,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    bool skipTextSegments = false,
    bool markUserMessageAsSent = true,
    bool allowTtsTextFallback = true,
    TraceLogger? trace,
  }) async {
    // 解析多模态标签分段（TTS + 表情包）
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
      // 解析失败，降级为直接交付原始文本
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
      'ttsSegments':
          segments.where((s) => s.type == MultimodalSegmentType.tts).length,
      'textSegments':
          segments.where((s) => s.type == MultimodalSegmentType.text).length,
      'stickerSegments':
          segments.where((s) => s.type == MultimodalSegmentType.sticker).length,
    });

    if (markUserMessageAsSent) {
      // 先标记用户消息为已发送
      await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) {
          final updatedMessages = c.messages.map((m) {
            if (m.id == userMsgId) return m.copyWith(status: 'sent');
            return m;
          }).toList();
          return c.copyWith(messages: updatedMessages);
        },
      );
    }

    // 按段顺序发送
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
        // 文本段：直接发送
        final textMsg = Message(
          id: genId('msg'),
          role: 'assistant',
          content: segment.content.trim(),
          createdAt: DateTime.now(),
          status: 'sent',
        );

        await _appendMessageToConversation(
          convId: convId,
          message: textMsg,
          lastMessagePreview: isLast ? textMsg.displayText : null,
        );

        AppLogger.info('ChatTtsHandler', '已发送文本段', metadata: {
          'segmentIndex': i,
          'textLength': segment.content.length,
        });
      } else if (segment.type == MultimodalSegmentType.sticker) {
        // 表情包段：直接发送
        final assetPath = segment.stickerData?['assetPath'] as String?;
        final stickerId = segment.stickerData?['stickerId'] as String?;
        final tag = segment.stickerData?['tag'] as String?;

        if (assetPath != null && assetPath.isNotEmpty) {
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
        }
      } else {
        // TTS 段：生成语音后发送
        final ttsText = segment.content.trim();
        _ref.read(chatStatusProvider.notifier).state =
            ChatStatus.generatingVoice;

        try {
          final audioUrl = await _convertTtsText(ttsText);

          if (audioUrl != null && audioUrl.isNotEmpty) {
            // 语音生成成功
            final audioMsgId = genId('msg');
            final audioMsg = Message.fromBlocks(
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

            await _appendMessageToConversation(
              convId: convId,
              message: audioMsg,
              lastMessagePreview: isLast ? '[语音]' : null,
            );

            AppLogger.info('ChatTtsHandler', '已发送语音段', metadata: {
              'segmentIndex': i,
              'textLength': ttsText.length,
              'audioUrlLength': audioUrl.length,
            });
          } else {
            // 语音生成失败，回退为文本
            if (allowTtsTextFallback) {
              await _sendFallbackText(convId, ttsText, isLast, i);
            } else {
              AppLogger.warning('ChatTtsHandler', 'TTS 生成失败，已跳过文本回退',
                  metadata: {
                    'segmentIndex': i,
                    'reason': 'empty_audio_url',
                  });
            }
          }
        } catch (e) {
          // 语音生成异常，回退为文本
          AppLogger.error('ChatTtsHandler', 'TTS 生成失败，回退为文本', metadata: {
            'segmentIndex': i,
            'error': e.toString(),
          });
          if (allowTtsTextFallback) {
            await _sendFallbackText(convId, ttsText, isLast, i);
          } else {
            AppLogger.warning('ChatTtsHandler', 'TTS 异常，已跳过文本回退', metadata: {
              'segmentIndex': i,
              'error': e.toString(),
            });
          }
          onTtsFallback?.call('convert_error');
        }
      }
    }

    AppLogger.info('ChatTtsHandler', '多模态分段交付完成', metadata: {
      'convId': convId,
      'totalSegments': segments.length,
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
  Future<void> _sendFallbackText(
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
  }

  /// 追加一条消息到对话
  Future<void> _appendMessageToConversation({
    required String convId,
    required Message message,
    String? lastMessagePreview,
  }) async {
    final now = DateTime.now();
    await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
            messages: [...c.messages, message],
            updatedAt: now,
            lastMessage: lastMessagePreview ?? c.lastMessage,
            lastMessageTime:
                lastMessagePreview != null ? now : c.lastMessageTime,
          ),
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
