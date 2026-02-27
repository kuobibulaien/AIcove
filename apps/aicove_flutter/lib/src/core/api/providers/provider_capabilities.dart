/// Provider能力声明
/// 用于描述每个AI提供商支持的功能
/// 遵循接口隔离原则(I)：客户端不应依赖不需要的接口
class ProviderCapabilities {
  /// 是否支持视觉输入（图片理解）
  final bool supportsVision;

  /// 是否支持音频输入
  final bool supportsAudio;

  /// 是否支持思考过程（Claude Thinking、OpenAI o1等）
  final bool supportsThinking;

  /// 是否支持图片生成
  final bool supportsImageGeneration;

  /// 是否支持流式响应
  final bool supportsStreaming;

  /// 是否支持函数调用
  final bool supportsFunctionCalling;

  /// 是否支持JSON模式
  final bool supportsJsonMode;

  /// 最大上下文长度（token数）
  final int? maxContextLength;

  /// 支持的文件类型（MIME类型列表）
  final List<String> supportedFileTypes;

  const ProviderCapabilities({
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsThinking = false,
    this.supportsImageGeneration = false,
    this.supportsStreaming = true,
    this.supportsFunctionCalling = false,
    this.supportsJsonMode = false,
    this.maxContextLength,
    this.supportedFileTypes = const [],
  });

  /// OpenAI的能力配置
  static const openai = ProviderCapabilities(
    supportsVision: true,
    supportsThinking: true, // o1系列支持
    supportsImageGeneration: true, // DALL-E
    supportsStreaming: true,
    supportsFunctionCalling: true,
    supportsJsonMode: true,
    maxContextLength: 128000, // GPT-4 Turbo
    supportedFileTypes: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'],
  );

  /// Gemini的能力配置
  static const gemini = ProviderCapabilities(
    supportsVision: true,
    supportsAudio: true,
    supportsThinking: false,
    supportsImageGeneration: false,
    supportsStreaming: true,
    supportsFunctionCalling: true,
    supportsJsonMode: true,
    maxContextLength: 1000000, // Gemini 1.5 Pro
    supportedFileTypes: [
      'image/jpeg',
      'image/png',
      'image/webp',
      'audio/wav',
      'audio/mp3',
      'video/mp4'
    ],
  );

  /// 豆包的能力配置
  static const doubao = ProviderCapabilities(
    supportsVision: false,
    supportsAudio: false,
    supportsThinking: false,
    supportsImageGeneration: false,
    supportsStreaming: true,
    supportsFunctionCalling: true,
    supportsJsonMode: false,
    maxContextLength: 32000,
    supportedFileTypes: [],
  );
}
