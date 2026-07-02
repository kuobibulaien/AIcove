import '../../../core/prompts/prompt_builtin_defaults.g.dart';

/// 表情包插件配置
class StickerConfig {
  /// 是否启用表情包插件
  final bool enabled;

  /// 系统提示词模板
  /// 支持 {tags} 占位符，运行时替换为实际可用的表情包标签列表
  final String systemPromptTemplate;

  static const String defaultSystemPromptTemplate =
      PromptBuiltinDefaults.stickerSystemDefault;

  const StickerConfig({
    this.enabled = true,
    this.systemPromptTemplate = defaultSystemPromptTemplate,
  });

  StickerConfig copyWith({
    bool? enabled,
    String? systemPromptTemplate,
  }) {
    return StickerConfig(
      enabled: enabled ?? this.enabled,
      systemPromptTemplate: systemPromptTemplate ?? this.systemPromptTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'systemPromptTemplate': systemPromptTemplate,
    };
  }

  factory StickerConfig.fromJson(Map<String, dynamic> json) {
    return StickerConfig(
      enabled: json['enabled'] as bool? ?? true,
      systemPromptTemplate: json['systemPromptTemplate'] as String? ??
          defaultSystemPromptTemplate,
    );
  }
}
