/// TTS 插件配置
class TtsConfig {
  /// 是否启用 TTS 插件
  final bool enabled;

  /// TTS API Key
  final String? apiKey;

  /// TTS API 请求 URL
  final String requestUrl;

  /// 参考音频 URL（用于克隆声音）
  final String? promptAudioUrl;

  /// 参考文本（与参考音频对应的文本）
  final String? promptText;

  /// 语速 (0.5 ~ 2.0)
  final double? speed;

  /// 最大字数限制（超过此限制会自动拆分）
  final int maxCharsPerChunk;

  /// 系统提示词模板
  final String systemPromptTemplate;

  TtsConfig({
    this.enabled = false,
    this.apiKey,
    required this.requestUrl,
    this.promptAudioUrl,
    this.promptText,
    this.speed,
    this.maxCharsPerChunk = 20,
    String? systemPromptTemplate,
  }) : systemPromptTemplate = systemPromptTemplate ??
            _defaultSystemPromptTemplate;

  static const String _defaultSystemPromptTemplate = '''
你可以使用 <tts>文本</tts> 标记来生成语音。

使用规则：
1. 将需要转换为语音的文本用 <tts></tts> 标记包裹
2. 每个 <tts></tts> 标记内的文本不要超过 20 个字
3. 一轮对话中可以使用多个 <tts></tts> 标记
4. 建议在关键句子或回复的重要部分使用语音

示例：
<tts>你好，很高兴见到你！</tts>
<tts>今天天气真不错。</tts>
''';

  TtsConfig copyWith({
    bool? enabled,
    String? apiKey,
    String? requestUrl,
    String? promptAudioUrl,
    String? promptText,
    double? speed,
    int? maxCharsPerChunk,
    String? systemPromptTemplate,
  }) {
    return TtsConfig(
      enabled: enabled ?? this.enabled,
      apiKey: apiKey ?? this.apiKey,
      requestUrl: requestUrl ?? this.requestUrl,
      promptAudioUrl: promptAudioUrl ?? this.promptAudioUrl,
      promptText: promptText ?? this.promptText,
      speed: speed ?? this.speed,
      maxCharsPerChunk: maxCharsPerChunk ?? this.maxCharsPerChunk,
      systemPromptTemplate: systemPromptTemplate ?? this.systemPromptTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'apiKey': apiKey,
      'requestUrl': requestUrl,
      'promptAudioUrl': promptAudioUrl,
      'promptText': promptText,
      'speed': speed,
      'maxCharsPerChunk': maxCharsPerChunk,
      'systemPromptTemplate': systemPromptTemplate,
    };
  }

  factory TtsConfig.fromJson(Map<String, dynamic> json) {
    return TtsConfig(
      enabled: json['enabled'] as bool? ?? false,
      apiKey: json['apiKey'] as String?,
      requestUrl: json['requestUrl'] as String? ?? '',
      promptAudioUrl: json['promptAudioUrl'] as String?,
      promptText: json['promptText'] as String?,
      speed: (json['speed'] as num?)?.toDouble(),
      maxCharsPerChunk: json['maxCharsPerChunk'] as int? ?? 20,
      systemPromptTemplate: json['systemPromptTemplate'] as String?,
    );
  }
}
