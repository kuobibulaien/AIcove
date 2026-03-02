/// 生成稳定唯一 ID。
///
/// 旧实现仅使用毫秒时间戳，在同一毫秒内连续创建多条消息时会撞 ID，
/// 进而导致列表 Key/GlobalKey 复用异常。这里增加“同时间戳递增序号”兜底。
int _lastEpochMicros = 0;
int _sameTickSequence = 0;

String genId(String prefix) {
  final nowMicros = DateTime.now().microsecondsSinceEpoch;
  if (nowMicros == _lastEpochMicros) {
    _sameTickSequence += 1;
  } else {
    _lastEpochMicros = nowMicros;
    _sameTickSequence = 0;
  }
  return '${prefix}_${nowMicros}_$_sameTickSequence';
}
