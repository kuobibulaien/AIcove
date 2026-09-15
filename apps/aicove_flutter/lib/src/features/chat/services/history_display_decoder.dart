import 'package:flutter/foundation.dart';

import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/models/message_block.dart';
import '../../observability/history_payload_stats.dart';
import '../domain/message.dart';
import 'chat_frontend_message_projection_service.dart';
import 'chat_message_projection_codec.dart';

class HistoryDisplayBatch {
  const HistoryDisplayBatch(this.messages, this.blocks,
      {required this.collectStats});
  final List<db.Message> messages;
  final List<db.MessageBlock> blocks;
  final bool collectStats;
}

class HistoryDisplayResult {
  const HistoryDisplayResult(this.messages, this.fallbackIds, this.metrics);
  final List<Message> messages;
  final List<String> fallbackIds;
  final Map<String, Object?> metrics;
}

/// 大载荷在 worker 中完成 JSON 解析、字段统计和显示转换；小窗口避免启动开销。
/// 只返回显示消息，不把解析后的原始 payload 再搬回界面线程。
Future<HistoryDisplayResult> decodeHistoryDisplay(
    HistoryDisplayBatch batch) async {
  final chars =
      batch.messages.fold<int>(0, (n, m) => n + (m.rawPayload?.length ?? 0)) +
          batch.blocks.fold<int>(0, (n, b) => n + b.data.length);
  final background = chars >= 256 * 1024;
  final clock = Stopwatch()..start();
  final result = background
      ? await compute(_decode, batch, debugLabel: 'history-display')
      : _decode(batch);
  return HistoryDisplayResult(result.messages, result.fallbackIds, {
    ...result.metrics,
    'backgroundDecode': background,
    'workerMs': clock.elapsedMilliseconds,
  });
}

HistoryDisplayResult _decode(HistoryDisplayBatch batch) {
  final clock = Stopwatch()..start();
  final blocks = <String, List<MessageBlock>>{};
  for (final row in batch.blocks) {
    final block = MessageBlockConverter.fromDb(row);
    if (block != null) (blocks[row.messageId] ??= []).add(block);
  }
  final raw = [
    for (final row in batch.messages)
      MessageConverter.fromDb(row, blocks: blocks[row.id])
  ];
  final fallbackIds = <String>[];
  // SQL 判断只保证非空数组；损坏/旧版快照仍交给原重建逻辑处理。
  for (final message in raw) {
    if (message.rawPayload?['__aicoveDisplayRead'] != 1) continue;
    try {
      if (ChatMessageProjectionCodec.projectedMessages(message.rawPayload)
          .isNotEmpty) {
        continue;
      }
    } on Object {
      // 回退原始行后，由既有解码器保留原异常或重建语义。
    }
    fallbackIds.add(message.id);
  }
  final decodeMs = clock.elapsedMilliseconds;
  clock.reset();
  final stats = batch.collectStats ? HistoryPayloadStats() : null;
  if (stats != null) {
    for (final message in raw) {
      stats.add(message.rawPayload);
    }
  }
  final statsMs = clock.elapsedMilliseconds;
  clock.reset();
  final projected = fallbackIds.isEmpty
      ? const ChatFrontendMessageProjectionService().projectMessages(raw)
      : const <Message>[];
  return HistoryDisplayResult(projected, fallbackIds, {
    'decodeMs': decodeMs,
    'projectionMs': clock.elapsedMilliseconds,
    'projectedCount': projected.length,
    if (stats != null) ...{
      ...stats.values,
      'payloadStatsMs': statsMs,
      'maxRawPayloadChars': batch.messages.fold<int>(
          0,
          (largest, m) => (m.rawPayload?.length ?? 0) > largest
              ? m.rawPayload!.length
              : largest),
    },
  });
}
