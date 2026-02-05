/// TTS 处理服务
///
/// 封装 TTS 语音消息的生成与交付逻辑。
///
/// 核心方法：`deliverSegmentedMessages()`
/// - 无 TTS 标签时：直接交付文本消息
/// - 有 TTS 标签时：按 <tts> 标签分段，文本直接发，语音生成完再发，按顺序交替
///
/// 更新记录：
/// - 2025-12-31: 从 chat_actions.dart 提取
/// - 2026-01-14: 添加 TTS 失败回退机制
/// - 2026-01-28: 重写为顺序发送模式，移除占位符机制
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
import 'chat_message_processor.dart';
import 'chat_send_service.dart';
import 'chat_types.dart';
import 'tts_fallback_notification.dart';

// 重新导出 TTS 失败通知服务，方便外部使用
export 'tts_fallback_notification.dart'
    show TtsFallbackNotificationService, ttsFallbackNotificationServiceProvider, TtsFallbackNotificationListener;

/// TTS 失败回退通知回调类型
typedef TtsFallbackNotifier = void Function(String reason);

/// TTS 处理服务
///
/// 提供统一的消息交付入口，自动处理 TTS 语音段的顺序生成和发送。
class ChatTtsHandler {
  final Ref _ref;
  final TtsPlayerManager? _ttsManager;

  static const Duration _ttsTimeout = Duration(seconds: 30);

  /// TTS 失败回退通知回调
  TtsFallbackNotifier? onTtsFallback;

  ChatTtsHandler(this._ref)
      : _ttsManager = _ref.read(ttsPlayerManagerProvider);

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
    TraceLogger? trace,
  }) async {
    final hasTtsEvents = pluginEvents.any((e) => e.type == 'tts_convert');

    // 检查是否有工具音频（路径 A：speak 工具产生的音频）
    final hasToolAudio = buildResult.messages.any(
      (m) => m.blocks?.any((b) => b is AudioBlock) ?? false,
    );

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

    // 有 TTS 标签 → 按段顺序发送
    await _deliverWithTtsSegments(
      convId: convId,
      userMsgId: userMsgId,
      replyText: replyText,
      trace: trace,
    );
  }

  /// 按 TTS 标签分段，顺序发送文本和语音消息
  ///
  /// 流程：
  /// 1. 解析 replyText 得到 [text, tts, text, tts, ...] 片段
  /// 2. 遍历片段：
  ///    - text 段 → 直接添加为文本消息
  ///    - tts 段 → 调用 TtsPlayerManager 生成语音 → 成功则发语音消息，失败则发文本消息
  /// 3. 每发完一段就更新对话，用户实时看到消息
  Future<void> _deliverWithTtsSegments({
    required String convId,
    required String userMsgId,
    required String replyText,
    TraceLogger? trace,
  }) async {
    // 解析 TTS 标签分段
    final segments = chatMessageProcessor.parseTtsSegments(replyText);

    if (segments.isEmpty) {
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

    AppLogger.info('ChatTtsHandler', '开始 TTS 分段交付', metadata: {
      'convId': convId,
      'segmentCount': segments.length,
      'ttsSegments': segments.where((s) => s.type == TtsSegmentType.tts).length,
      'textSegments': segments.where((s) => s.type == TtsSegmentType.text).length,
    });

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

    // 按段顺序发送
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      if (segment.type == TtsSegmentType.text) {
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
      } else {
        // TTS 段：生成语音后发送
        final ttsText = segment.content.trim();

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
            await _sendFallbackText(convId, ttsText, isLast, i);
          }
        } catch (e) {
          // 语音生成异常，回退为文本
          AppLogger.error('ChatTtsHandler', 'TTS 生成失败，回退为文本', metadata: {
            'segmentIndex': i,
            'error': e.toString(),
          });
          await _sendFallbackText(convId, ttsText, isLast, i);
          onTtsFallback?.call('convert_error');
        }
      }
    }

    AppLogger.info('ChatTtsHandler', 'TTS 分段交付完成', metadata: {
      'convId': convId,
      'totalSegments': segments.length,
    });
  }

  /// 调用 TTS 服务生成语音
  ///
  /// 通过 TtsPlayerManager 生成，利用其已有的队列机制和 TtsService 配置
  Future<String?> _convertTtsText(String text) async {
    if (_ttsManager == null) return null;

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
    sub = _ttsManager!.processedStream.listen((item) {
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
    await _ttsManager!.addEvents([event]);

    final result = await completer.future;
    timeout.cancel();
    return result;
  }

  /// TTS 失败时发送回退文本消息
  Future<void> _sendFallbackText(String convId, String text, bool isLast, int segmentIndex) async {
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
        lastMessageTime: lastMessagePreview != null ? now : c.lastMessageTime,
      ),
    );
  }
}

/// Provider
final chatTtsHandlerProvider = Provider((ref) {
  final handler = ChatTtsHandler(ref);

  // 连接到全局通知服务
  try {
    final notificationService = ref.read(ttsFallbackNotificationServiceProvider);
    handler.onTtsFallback = notificationService.notify;
  } catch (_) {
    // 服务未初始化，忽略
  }

  return handler;
});
