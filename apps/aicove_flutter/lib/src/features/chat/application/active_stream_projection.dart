import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/message_block.dart';
import '../domain/message.dart';

/// 流式活跃尾投影（G2.1 瞬态通道，任务 07-20-stream-active-bubble）。
///
/// 仅供 UI 渲染流式期间的活跃尾文本与「生成中」占位——
/// 不落任何持久层，也绝不参与模型上下文组装（DB raw message 仍是唯一真相源）。
///
/// 身份与并发契约（design.md §2.1）：
/// - `generationSeq` 取 ChatActions 的 runId（跨 delivery 实例全局单调）；
/// - `writeEpoch` 为同一 delivery 内的流内 reset 版本；
/// - 比较键 `(generationSeq, writeEpoch)` 字典序 CAS：旧流的 publish 与 clear
///   都不得覆盖/清除新流的条目。
enum ActiveStreamPhase { thinking, streamingTail }

class ActiveStreamProjection {
  final String conversationId;
  final int generationSeq;
  final int writeEpoch;

  /// 窗口中活跃壳消息的 id；thinking 阶段可为 null（壳尚未落位）。
  final String? tailMessageId;

  /// 活跃尾实时文本。只能来自流式物化管线的 active descriptor
  /// （已做可见性 sanitize 与标签拆分），禁止直接使用 raw buffer（design §2.4）。
  final String tailText;
  final ActiveStreamPhase phase;

  const ActiveStreamProjection({
    required this.conversationId,
    required this.generationSeq,
    required this.writeEpoch,
    required this.tailMessageId,
    required this.tailText,
    required this.phase,
  });

  ActiveStreamProjection copyWith({
    String? tailMessageId,
    String? tailText,
    ActiveStreamPhase? phase,
    int? writeEpoch,
  }) {
    return ActiveStreamProjection(
      conversationId: conversationId,
      generationSeq: generationSeq,
      writeEpoch: writeEpoch ?? this.writeEpoch,
      tailMessageId: tailMessageId ?? this.tailMessageId,
      tailText: tailText ?? this.tailText,
      phase: phase ?? this.phase,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ActiveStreamProjection &&
        other.conversationId == conversationId &&
        other.generationSeq == generationSeq &&
        other.writeEpoch == writeEpoch &&
        other.tailMessageId == tailMessageId &&
        other.tailText == tailText &&
        other.phase == phase;
  }

  @override
  int get hashCode => Object.hash(conversationId, generationSeq, writeEpoch,
      tailMessageId, tailText, phase);
}

/// 新旧投影通道的切换开关（design §2.8）。
///
/// 默认 false＝旧全量 transient 路径；测试用 ProviderScope override 做 on/off 对照；
/// 全链路对照通过后再单独翻默认值（独立可 revert 的小改动）。
class StreamProjectionPolicy {
  final bool useActiveStreamChannel;
  const StreamProjectionPolicy({this.useActiveStreamChannel = false});
}

final streamProjectionPolicyProvider = Provider<StreamProjectionPolicy>(
  (ref) => const StreamProjectionPolicy(),
);

/// 单一 owner 的活跃流投影表：key=conversationId，只保留活跃会话条目
/// （codex 审查 B3 裁决：非 family，流结束即移除条目，无残留实例）。
class ActiveStreamProjectionsNotifier
    extends Notifier<Map<String, ActiveStreamProjection>> {
  @override
  Map<String, ActiveStreamProjection> build() =>
      const <String, ActiveStreamProjection>{};

  /// CAS publish：仅当 `(generationSeq, writeEpoch)` 不落后于现值才写入。
  /// 返回是否落地（供调用方测试断言，不用于业务分支）。
  bool publish(ActiveStreamProjection next) {
    final current = state[next.conversationId];
    if (current != null && _isNewer(current, next)) {
      return false;
    }
    if (current == next) {
      return true;
    }
    state = <String, ActiveStreamProjection>{
      ...state,
      next.conversationId: next,
    };
    return true;
  }

  /// CAS clear：仅当条目仍属于 `generationSeq` 这一代才移除——
  /// 旧流迟到的 clear 不得清掉新流（B1）。
  bool clear(String conversationId, {required int generationSeq}) {
    final current = state[conversationId];
    if (current == null) return false;
    if (current.generationSeq != generationSeq) return false;
    final next = <String, ActiveStreamProjection>{...state}
      ..remove(conversationId);
    state = next;
    return true;
  }

  static bool _isNewer(
    ActiveStreamProjection current,
    ActiveStreamProjection candidate,
  ) {
    if (current.generationSeq != candidate.generationSeq) {
      return current.generationSeq > candidate.generationSeq;
    }
    return current.writeEpoch > candidate.writeEpoch;
  }
}

final activeStreamProjectionsProvider = NotifierProvider<
    ActiveStreamProjectionsNotifier, Map<String, ActiveStreamProjection>>(
  ActiveStreamProjectionsNotifier.new,
);

/// 把活跃尾壳消息替换为通道实时文本（仅 UI 渲染层使用）。
///
/// 命中条件：通道处于 streamingTail、文本非空、壳消息恰为单 TextBlock。
/// 不命中时原样返回，绝不修改持久层或模型上下文。
Message resolveActiveStreamTailMessage(
  Message message,
  ActiveStreamProjection? live,
) {
  if (live == null ||
      live.phase != ActiveStreamPhase.streamingTail ||
      live.tailText.isEmpty ||
      live.tailMessageId != message.id) {
    return message;
  }
  final blocks = message.blocks;
  if (blocks == null || blocks.length != 1) return message;
  final block = blocks.single;
  if (block is! TextBlock) return message;
  if (block.content == live.tailText) return message;
  return message.copyWith(
    content: live.tailText,
    blocks: <MessageBlock>[block.copyWith(content: live.tailText)],
  );
}
