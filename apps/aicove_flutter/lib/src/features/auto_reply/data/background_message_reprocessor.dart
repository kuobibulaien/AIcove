import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/domain/message.dart' as model;

import '../../../core/app_logger.dart';
import '../../../core/media/media_store.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/services/chat_message_projection_codec.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/services/chat_tts_handler.dart';
import '../../settings/app_settings.dart';
import '../../plugins/plugin_content_tags.dart';
import '../../content_tags/domain/content_tag_scanner.dart';
import '../../chat/services/chat_history_store.dart';

final backgroundReprocessDeviceIdProvider = FutureProvider<String>(
  (_) => MediaStore.localDeviceId,
);

final backgroundMessageReprocessorProvider =
    Provider<BackgroundMessageReprocessor>((ref) {
      return BackgroundMessageReprocessor(ref);
    });

/// 后台消息多模态补渲染。
///
/// WorkManager 后台 isolate 只能写纯文本消息和发通知，无法执行
/// TTS/生图插件链；后台投递的消息（id 前缀 `bg_`）若 raw 文本携带
/// `<tts>` / `<image>` / `<emoji>` 标签，会在 App 回到前台时由本服务
/// 准备插件结果后原子更新原消息快照，让多模态内容补齐。
///
/// 安全约束：
/// - 只处理最近 48 小时内的后台消息；
/// - 仅来源设备处理；旧数据只在 Android/iOS 上处理；
/// - 保留原始 ID 和时间；本机最多尝试三次，最后一次失败降为文字；
/// - 快照与 `bg_reprocessed` 同时提交；并发编辑时放弃旧结果。
class BackgroundMessageReprocessor {
  BackgroundMessageReprocessor(this._ref);

  static const String _reprocessedFlagKey = 'bg_reprocessed';
  static const _attemptLimit = 3;
  // Deliberately outside the synced aicove.* preference namespace.
  static const _attemptPrefix = 'local.bg_reprocess.attempts.';
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
        metadata: {
          'category': 'backgroundDelivery',
          'event': 'reprocessSweepFailed',
          'phase': 'sweep',
          'result': 'failed',
          'errorType': e.runtimeType.toString(),
        },
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
    final rows =
        await (db.select(db.messages)..where(
              (t) =>
                  t.id.like('bg_%') &
                  t.deletedAt.isNull() &
                  t.replacedBy.isNull() &
                  t.createdAt.isBiggerOrEqualValue(cutoff),
            ))
            .get();
    if (rows.isEmpty) return;

    final deviceId = await _ref.read(
      backgroundReprocessDeviceIdProvider.future,
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    final conversations = await _ref.read(conversationsProvider.future);
    final settings = await _ref.read(appSettingsProvider.future);
    final chatSendService = _ref.read(chatSendServiceProvider);
    final ttsHandler = _ref.read(chatTtsHandlerProvider);

    for (final row in rows) {
      if (!row.id.startsWith('bg_')) continue;
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
      final origin = payload['bg_origin_device_id'];
      if (origin is String && origin.isNotEmpty) {
        if (origin != deviceId) continue;
      } else if (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS) {
        continue;
      }

      final rawReply = (ChatMessageProjectionCodec.rawReplyText(payload) ?? '')
          .trim();
      final hasMedia = firstPartyContentTagScanner
          .scan(rawReply)
          .any(
            (segment) =>
                segment is ContentTagElement &&
                segment.closed &&
                const {
                  'tts',
                  'image',
                  'emoji',
                  'sticker',
                }.contains(segment.spec.name),
          );
      if (rawReply.isEmpty || !hasMedia) {
        continue;
      }

      final conversation = conversations
          .where((c) => c.id == row.conversationId)
          .toList(growable: false);
      if (conversation.isEmpty) {
        continue;
      }

      final clock = Stopwatch()..start();
      try {
        final key = '$_attemptPrefix${row.id}';
        final attempts = preferences.getInt(key) ?? 0;
        final terminalAttempt = attempts >= _attemptLimit - 1;
        late model.Message raw;
        late List<model.Message> projected;
        if (attempts >= _attemptLimit) {
          (raw, projected) = _textFallback(
            row.id,
            row.createdAt,
            rawReply,
            payload,
          );
        } else {
          // Persist before any paid work: an isolate/process death consumes an
          // attempt too, instead of resetting the budget on the next foreground.
          if (!await preferences.setInt(key, attempts + 1)) {
            throw StateError('Background attempt budget could not be saved');
          }
          try {
            final apiResult = await chatSendService
                .processAssistantReplyWithPlugins(
                  conv: conversation.first,
                  rawReplyText: rawReply,
                );
            final buildResult = chatSendService.buildAssistantMessages(
              apiResult: apiResult,
              settings: settings,
            );
            raw = buildResult.rawMessage!.copyWith(
              id: row.id,
              createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
            );
            projected = await ttsHandler.prepareBackgroundSnapshot(
              convId: row.conversationId,
              rawMessage: raw,
              buildResult: buildResult,
              replyText: apiResult.rawReplyText,
              pluginEvents: apiResult.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
              fallbackFailedMedia: terminalAttempt,
            );
          } catch (_) {
            if (!terminalAttempt) rethrow;
            (raw, projected) = _textFallback(
              row.id,
              row.createdAt,
              rawReply,
              payload,
            );
          }
        }
        final committed = await _ref
            .read(chatHistoryStoreProvider)
            .completeBackgroundMessageSnapshot(
              original: row,
              processedRaw: raw,
              projectedMessages: projected,
            );
        if (!committed) continue;
        AppLogger.info(
          'BackgroundMessageReprocessor',
          'Background message snapshot completed',
          metadata: {
            'messageId': row.id,
            'conversationId': row.conversationId,
            'category': 'backgroundDelivery',
            'event': 'reprocessed',
            'entityId': row.id,
            'phase': 'snapshot',
            'result': 'success',
            'elapsedMs': clock.elapsedMilliseconds,
          },
        );
      } catch (e) {
        AppLogger.warning(
          'BackgroundMessageReprocessor',
          'Failed to reprocess background message',
          metadata: {
            'messageId': row.id,
            'category': 'backgroundDelivery',
            'event': 'reprocessFailed',
            'elapsedMs': clock.elapsedMilliseconds,
            'entityId': row.id,
            'phase': 'snapshot',
            'result': 'failed',
            'errorType': e.runtimeType.toString(),
          },
        );
      }
    }
  }

  /// Used only when preparation itself fails or the persisted budget is spent.
  /// Keep the original raw payload; explicit display projections retain tag text.
  (model.Message, List<model.Message>) _textFallback(
    String id,
    int createdAt,
    String reply,
    Map<String, dynamic> payload,
  ) {
    final text = firstPartyContentTagScanner.scan(reply).map((segment) {
      if (segment is! ContentTagElement || !segment.closed) return segment.raw;
      return switch (segment.spec.name) {
        'tts' => segment.inner,
        'image' => '[图片：${segment.inner}]',
        'emoji' ||
        'sticker' => '[表情：${segment.attributes['tag'] ?? segment.inner}]',
        _ => segment.raw,
      };
    }).join();
    final raw = model.Message(
      id: id,
      role: 'assistant',
      content: reply,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      rawPayload: payload,
    );
    return (
      raw,
      [
        model.Message(
          id: '${id}_fallback',
          role: 'assistant',
          content: text,
          sourceMessageId: id,
          createdAt: raw.createdAt,
        ),
      ],
    );
  }
}
