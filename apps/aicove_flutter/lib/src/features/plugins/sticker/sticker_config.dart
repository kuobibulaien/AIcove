import '../../../core/prompts/prompt_builtin_defaults.g.dart';

/// 表情包插件配置
class StickerConfig {
  /// 全局常开：持久化读取时恒为 true；是否启用由角色/会话的插件选择决定。
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

  StickerConfig copyWith({bool? enabled, String? systemPromptTemplate}) {
    return StickerConfig(
      enabled: enabled ?? this.enabled,
      systemPromptTemplate: systemPromptTemplate ?? this.systemPromptTemplate,
    );
  }

  Map<String, dynamic> toJson() {
    return {'enabled': enabled, 'systemPromptTemplate': systemPromptTemplate};
  }

  factory StickerConfig.fromJson(Map<String, dynamic> json) {
    return StickerConfig(
      // 全局开关已移除，忽略旧存储值
      enabled: true,
      systemPromptTemplate:
          json['systemPromptTemplate'] as String? ??
          defaultSystemPromptTemplate,
    );
  }
}
