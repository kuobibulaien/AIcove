import 'voice_call_ports.dart';

/// 2026-10-12 之前的通话存档：逐句记录只在通话那台设备的 `call_sessions`／
/// `call_turns` 里。之后的通话把记录存进通话气泡（`CallRecordBlock.turns`），
/// 这里只读，给旧气泡兜底。
class CallRecord {
  const CallRecord({
    required this.id,
    required this.conversationId,
    required this.startedAt,
    required this.endedAt,
    required this.duration,
    required this.turns,
  });

  final String id;
  final String conversationId;
  final DateTime startedAt;
  final DateTime endedAt;

  /// 接通到挂断的时长（不含接通前的准备时间）。
  final Duration duration;
  final List<CallTurn> turns;
}

abstract interface class CallRecordStorePort {
  /// 本机没有这通电话（例如气泡从别的设备同步过来）时返回 null。
  Future<CallRecord?> load(String callId);
}
