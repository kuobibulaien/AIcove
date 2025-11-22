/// Block类型枚举
/// 定义消息中可以包含的各种内容块类型
///
/// 遵循开闭原则(O)：新增Block类型无需修改现有代码
enum BlockType {
  /// 未知类型（用于初始化）
  unknown,

  /// 主要文本内容
  mainText,

  /// 思考过程（Claude Thinking、OpenAI o1等）
  thinking,

  /// 翻译内容
  translation,

  /// 图片内容（用户上传或AI生成）
  image,

  /// 代码块
  code,

  /// 工具调用结果（TTS、搜索等）
  tool,

  /// 文件内容（用户上传的文档）
  file,

  /// 错误信息
  error,

  /// 引用/来源（网页搜索结果等）
  citation,

  /// 视频内容
  video,

  /// 音频内容
  audio,

  /// 表情包内容
  emoji,
}
