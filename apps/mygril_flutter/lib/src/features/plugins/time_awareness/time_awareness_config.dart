/// 时间增强插件配置
/// 
/// 让 AI 感知现实世界的时间，通过在消息中注入时间戳和当前时间信息
class TimeAwarenessConfig {
  /// 是否启用插件
  final bool enabled;
  
  /// 是否为历史消息添加时间戳前缀
  /// 格式: [YYYY-MM-DD HH:mm]: 消息内容
  final bool includeMessageTimestamp;
  
  /// 是否在系统提示词中注入当前时间
  final bool includeCurrentTime;
  
  /// 当前时间提示词模板
  /// 支持 {datetime} 占位符
  final String currentTimePromptTemplate;

  TimeAwarenessConfig({
    this.enabled = false,
    this.includeMessageTimestamp = true,
    this.includeCurrentTime = true,
    this.currentTimePromptTemplate = '当前时间: {datetime}',
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'includeMessageTimestamp': includeMessageTimestamp,
    'includeCurrentTime': includeCurrentTime,
    'currentTimePromptTemplate': currentTimePromptTemplate,
  };

  factory TimeAwarenessConfig.fromJson(Map<String, dynamic> json) {
    return TimeAwarenessConfig(
      enabled: json['enabled'] as bool? ?? false,
      includeMessageTimestamp: json['includeMessageTimestamp'] as bool? ?? true,
      includeCurrentTime: json['includeCurrentTime'] as bool? ?? true,
      currentTimePromptTemplate: json['currentTimePromptTemplate'] as String? ?? '当前时间: {datetime}',
    );
  }

  TimeAwarenessConfig copyWith({
    bool? enabled,
    bool? includeMessageTimestamp,
    bool? includeCurrentTime,
    String? currentTimePromptTemplate,
  }) {
    return TimeAwarenessConfig(
      enabled: enabled ?? this.enabled,
      includeMessageTimestamp: includeMessageTimestamp ?? this.includeMessageTimestamp,
      includeCurrentTime: includeCurrentTime ?? this.includeCurrentTime,
      currentTimePromptTemplate: currentTimePromptTemplate ?? this.currentTimePromptTemplate,
    );
  }
}
