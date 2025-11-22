/// Block状态枚举
/// 表示每个内容块的处理状态
enum BlockStatus {
  /// 等待处理
  pending,

  /// 正在处理（如生成图片、合成语音）
  processing,

  /// 正在流式接收内容
  streaming,

  /// 处理成功
  success,

  /// 处理失败
  error,

  /// 处理暂停
  paused,
}
