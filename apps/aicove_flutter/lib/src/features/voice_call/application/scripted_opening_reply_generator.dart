import '../domain/voice_call_ports.dart';

/// 角色主动来电时，接通后的第一句是预先写好的开场白（方案 12 §4.8）：
/// 第一次在没人说过话时生成，直接说出 [openingLine]，之后交给 [inner]。
class ScriptedOpeningReplyGenerator implements CallReplyGeneratorPort {
  ScriptedOpeningReplyGenerator(this.inner, String openingLine)
    : _openingLine = openingLine.trim();

  final CallReplyGeneratorPort inner;
  String? _openingLine;

  @override
  Stream<String> streamReply(List<CallTurn> turns) {
    final line = _openingLine;
    _openingLine = null;
    if (turns.isEmpty && line != null && line.isNotEmpty) {
      return Stream.value(line);
    }
    return inner.streamReply(turns);
  }
}
