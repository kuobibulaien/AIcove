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
import '../../chat/services/conversation_short_window_store.dart';

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
/// - 仅来源设备处理；旧数据只在 Android/iOS 上处理；
/// - 保留原始 ID 和时间；本机最多尝试三次，最后一次失败降为文字；
/// - 快照与 `bg_reprocessed` 同时提交；并发编辑时放弃旧结果。
class BackgroundMessageReprocessor {
  BackgroundMessageReprocessor(this._ref);

  static const String _reprocessedFlagKey = 'bg_reprocessed';
  static const _attemptLimit = 3;
  // Deliberately outside the synced aicove.* preference namespace.
  static const _attemptPrefix = 'local.bg_reprocess.attempts.';

  static final RegExp _legacyEmojiTagPattern = RegExp(
    r'<(/?)emoji(?=[\s/>])',
    caseSensitive: false,
  );

  static String _normalizeLegacyEmojiTags(String text) =>
      text.replaceAllMapped(
        _legacyEmojiTagPattern,
        (match) => '<${match[1]}sticker',
      );

  final Ref _ref;
  Future<void>? _running;
  bool _again = false;

  Future<void> reprocessRecentBackgroundMessages() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _sweep();
    } while (_again);
  }

  Future<void> _sweep() async {
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
    }
  }

  Future<void> _reprocessInternal() async {
    final db = _ref.read(databaseProvider);
    // Background isolates use another connection, so foreground drift streams
    // need an explicit invalidation before reading their committed rows.
    db.markTablesUpdated({
      db.conversations,
      db.messages,
      db.messageBlocks,
      db.messageProjectionMappings,
    });
    final rows =
        await (db.select(db.messages)..where(
              (t) =>
                  t.id.like('bg_%') &
                  t.deletedAt.isNull() &
                  t.replacedBy.isNull(),
            ))
            .get();

    // Repair every warm timeline before media/ownership/processed gates: plain
    // text and already-enriched messages can also arrive while the app sleeps.
    final cache = _ref.read(conversationTimelineCacheProvider);
    for (final conversationId in cache.loadedConversationIds) {
      if (cache.peekWindow(conversationId: conversationId, limit: 1) == null) {
        continue;
      }
      final cached = await cache.loadCachedMessages(conversationId);
      final cachedRawIds = {
        for (final message in cached) message.sourceMessageIdOrSelf,
      };
      final recent = await db
          .customSelect(
            'SELECT id FROM messages WHERE conversation_id = ? '
            'AND deleted_at IS NULL AND replaced_by IS NULL '
            'ORDER BY created_at DESC, rowid DESC LIMIT ?',
            variables: [
              Variable<String>(conversationId),
              const Variable<int>(kConversationTimelineSeedMessageCount),
            ],
            readsFrom: {db.messages},
          )
          .get();
      if (recent.any((row) => !cachedRawIds.contains(row.read<String>('id'))) ||
          rows.any(
            (row) =>
                row.conversationId == conversationId &&
                row.id.startsWith('bg_') &&
                !cachedRawIds.contains(row.id),
          )) {
        // A warm window may also contain a foreground stream draft with no
        // persisted raw yet. Reload committed rows without losing that draft.
        final stored =
            await (db.selectOnly(db.messages)
                  ..addColumns([db.messages.id])
                  ..where(db.messages.id.isIn(cachedRawIds)))
                .get();
        final storedRawIds = {
          for (final row in stored) row.read(db.messages.id)!,
        };
        final transient = cached
            .where(
              (message) =>
                  !storedRawIds.contains(message.sourceMessageIdOrSelf),
            )
            .toList(growable: false);
        await cache.reloadConversationFromRawStore(conversationId);
        if (transient.isNotEmpty) {
          await cache.replaceMessagesTransient(
            conversationId: conversationId,
            messages: transient,
          );
        }
      }
    }

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
          .scan(_normalizeLegacyEmojiTags(rawReply))
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
            if (projected.isEmpty) {
              (raw, projected) = _textFallback(
                row.id,
                row.createdAt,
                rawReply,
                payload,
              );
            }
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
    final displayInput = _normalizeLegacyEmojiTags(reply);
    var text = firstPartyContentTagScanner.scan(displayInput).map((segment) {
      if (segment is! ContentTagElement || !segment.closed) return segment.raw;
      if (segment.spec.name == 'sticker') {
        final tag = (segment.attributes['tag'] ?? segment.inner).trim();
        return tag.isEmpty ? '[表情]' : '[表情：$tag]';
      }
      return switch (segment.spec.name) {
        'tts' => segment.inner,
        'image' => '[图片：${segment.inner}]',
        _ => segment.raw,
      };
    }).join();
    if (text.trim().isEmpty) {
      text = ChatMessageProjectionCodec.displayReplyText(payload)?.trim() ?? '';
      if (text.isEmpty) text = '[消息]';
    }
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
