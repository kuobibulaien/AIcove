/// 表情包插件配置
class StickerConfig {
  /// 是否启用表情包插件
  final bool enabled;

  /// 系统提示词模板
  /// 支持 {tags} 占位符，运行时替换为实际可用的表情包标签列表
  final String systemPromptTemplate;

  static const String defaultSystemPromptTemplate = '''
你可以在回复中使用表情包来增加趣味性。使用方法：在合适的地方用 [标签] 标记。

可用的表情包标签：{tags}

示例：
- "晚安呀~ [晚安]"
- "太感谢你了！[谢谢]"
- "好累啊 [摸鱼]"

注意：
- 不要每句话都用表情包，适度使用
- 表情包放在句尾效果更自然
- 同义词会自动匹配（如"睡觉"会匹配到"晚安"组的表情包）''';

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
      systemPromptTemplate:
          systemPromptTemplate ?? this.systemPromptTemplate,
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
