import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' hide MessageBlock, Provider;
import '../../../core/database/database_provider.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/services/chat_message_projection_codec.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/services/chat_tts_handler.dart';
import '../../settings/app_settings.dart';

final backgroundMessageReprocessorProvider =
    Provider<BackgroundMessageReprocessor>((ref) {
  return BackgroundMessageReprocessor(ref);
});

/// 后台消息多模态补渲染。
///
/// WorkManager 后台 isolate 只能写纯文本消息和发通知，无法执行
/// TTS/生图插件链；后台投递的消息（id 前缀 `bg_`）若 raw 文本携带
/// `<tts>` / `<image>` / `<emoji>` 标签，会在 App 回到前台时由本服务
/// 重新走聊天主链路的插件解析与分段交付，让多模态内容补齐。
///
/// 安全约束：
/// - 只处理最近 48 小时内的后台消息；
/// - 只在该消息仍是会话最后一条时才替换重发，避免打乱时间线；
/// - 处理过/跳过的消息会打上 `bg_reprocessed` 标记，不重复扫描。
class BackgroundMessageReprocessor {
  BackgroundMessageReprocessor(this._ref);

  static const String _reprocessedFlagKey = 'bg_reprocessed';
  static final RegExp _multimodalTagRegex = RegExp(
    r'<(tts|image|emoji)>',
    caseSensitive: false,
  );

  final Ref _ref;
  bool _running = false;

  Future<void> reprocessRecentBackgroundMessages() async {
    if (_running) return;
    _running = true;
    try {
      await _reprocessInternal();
    } catch (e) {
      AppLogger.warning(
        'BackgroundMessageReprocessor',
        'Reprocess sweep failed',
        metadata: {'error': e.toString()},
      );
    } finally {
      _running = false;
    }
  }

  Future<void> _reprocessInternal() async {
    final db = _ref.read(databaseProvider);
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 48))
        .millisecondsSinceEpoch;
    final rows = await (db.select(db.messages)
          ..where((t) =>
              t.id.like('bg_%') &
              t.deletedAt.isNull() &
              t.createdAt.isBiggerOrEqualValue(cutoff)))
        .get();
    if (rows.isEmpty) return;

    final conversations = await _ref.read(conversationsProvider.future);
    final settings = await _ref.read(appSettingsProvider.future);
    final chatSendService = _ref.read(chatSendServiceProvider);
    final ttsHandler = _ref.read(chatTtsHandlerProvider);
    final msgRepo = _ref.read(messageRepositoryProvider);

    for (final row in rows) {
      final rawPayloadText = row.rawPayload;
      if (rawPayloadText == null || rawPayloadText.isEmpty) continue;

      Map<String, dynamic> payload;
      try {
        final decoded = jsonDecode(rawPayloadText);
        if (decoded is! Map) continue;
        payload = Map<String, dynamic>.from(decoded.cast<String, dynamic>());
      } catch (_) {
        continue;
      }
      if (payload[_reprocessedFlagKey] == true) continue;

      final rawReply =
          (ChatMessageProjectionCodec.rawReplyText(payload) ?? '').trim();
      if (rawReply.isEmpty || !_multimodalTagRegex.hasMatch(rawReply)) {
        continue;
      }

      // 只有仍是会话最后一条消息时才允许替换重发，避免打乱时间线
      final lastMessage = await msgRepo.getLastMessageStable(
        row.conversationId,
      );
      if (lastMessage?.id != row.id) {
        await _markProcessed(db, row.id, payload, replaced: false);
        continue;
      }

      final conversation = conversations
          .where((c) => c.id == row.conversationId)
          .toList(growable: false);
      if (conversation.isEmpty) {
        await _markProcessed(db, row.id, payload, replaced: false);
        continue;
      }

      try {
        final apiResult = await chatSendService.processAssistantReplyWithPlugins(
          conv: conversation.first,
          rawReplyText: rawReply,
        );
        if (apiResult.pluginEvents.isEmpty) {
          await _markProcessed(db, row.id, payload, replaced: false);
          continue;
        }

        final buildResult = chatSendService.buildAssistantMessages(
          apiResult: apiResult,
          settings: settings,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        await msgRepo.softDelete(
          row.id,
          now,
          now + const Duration(days: 7).inMilliseconds,
        );
        await ttsHandler.deliverSegmentedMessages(
          convId: row.conversationId,
          userMsgId: '',
          buildResult: buildResult,
          replyText: apiResult.rawReplyText,
          pluginEvents: apiResult.pluginEvents,
          ttsEnabled: settings.ttsEnabled,
        );
        AppLogger.info(
          'BackgroundMessageReprocessor',
          'Background message reprocessed with plugins',
          metadata: {
            'messageId': row.id,
            'conversationId': row.conversationId,
            'pluginEvents': apiResult.pluginEvents.length,
          },
        );
      } catch (e) {
        AppLogger.warning(
          'BackgroundMessageReprocessor',
          'Failed to reprocess background message',
          metadata: {
            'messageId': row.id,
            'error': e.toString(),
          },
        );
      }
    }
  }

  Future<void> _markProcessed(
    AppDatabase db,
    String messageId,
    Map<String, dynamic> payload, {
    required bool replaced,
  }) async {
    payload[_reprocessedFlagKey] = true;
    try {
      await (db.update(db.messages)..where((t) => t.id.equals(messageId)))
          .write(MessagesCompanion(rawPayload: Value(jsonEncode(payload))));
    } catch (e) {
      AppLogger.warning(
        'BackgroundMessageReprocessor',
        'Failed to mark message reprocessed',
        metadata: {'messageId': messageId, 'error': e.toString()},
      );
    }
  }
}
