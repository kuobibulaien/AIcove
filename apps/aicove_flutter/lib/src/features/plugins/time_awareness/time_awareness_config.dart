/// 时间增强插件配置
///
/// 让 AI 感知现实世界的时间，通过在消息中注入时间戳和当前时间信息
class TimeAwarenessConfig {
  static const String defaultCurrentTimePromptTemplate = '当前时间: {datetime}';
  static const String fallbackCurrentTimePromptTemplate = '当前时间为{datetime}';

  /// 全局常开：持久化读取时恒为 true；是否启用由角色/会话的插件选择决定。
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
    this.enabled = true,
    this.includeMessageTimestamp = true,
    this.includeCurrentTime = true,
    this.currentTimePromptTemplate = defaultCurrentTimePromptTemplate,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'includeMessageTimestamp': includeMessageTimestamp,
    'includeCurrentTime': includeCurrentTime,
    'currentTimePromptTemplate': currentTimePromptTemplate,
  };

  factory TimeAwarenessConfig.fromJson(Map<String, dynamic> json) {
    return TimeAwarenessConfig(
      // 全局开关已移除，忽略旧存储值
      enabled: true,
      includeMessageTimestamp: json['includeMessageTimestamp'] as bool? ?? true,
      includeCurrentTime: json['includeCurrentTime'] as bool? ?? true,
      currentTimePromptTemplate:
          json['currentTimePromptTemplate'] as String? ??
          defaultCurrentTimePromptTemplate,
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
      includeMessageTimestamp:
          includeMessageTimestamp ?? this.includeMessageTimestamp,
      includeCurrentTime: includeCurrentTime ?? this.includeCurrentTime,
      currentTimePromptTemplate:
          currentTimePromptTemplate ?? this.currentTimePromptTemplate,
    );
  }
}
