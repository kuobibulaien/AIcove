/// 表情包插件配置
class StickerConfig {
  /// 是否启用表情包插件
  final bool enabled;
  
  const StickerConfig({
    this.enabled = true,
  });
  
  StickerConfig copyWith({
    bool? enabled,
  }) {
    return StickerConfig(
      enabled: enabled ?? this.enabled,
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
    };
  }
  
  factory StickerConfig.fromJson(Map<String, dynamic> json) {
    return StickerConfig(
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}
