import '../../../core/prompts/prompt_builtin_defaults.g.dart';

/// 时间增强插件配置
///
/// 通过系统提醒提供当前时间和上一条用户消息时间
class TimeAwarenessConfig {
  static const String defaultCurrentTimePromptTemplate = '当前时间: {datetime}';
  static const String defaultSystemGuidePromptTemplate =
      PromptBuiltinDefaults.timeAwarenessSystemDefault;
  static const String fallbackCurrentTimePromptTemplate = '当前时间为{datetime}';

  /// 全局常开：持久化读取时恒为 true；是否启用由角色/会话的插件选择决定。
  final bool enabled;

  /// 单次请求是否告知当前时间；由角色选项决定，不读取全局存储值。
  final bool includeCurrentTime;

  /// 当前时间提示词模板
  /// 支持 {datetime} 占位符
  final String currentTimePromptTemplate;

  final String systemGuidePromptTemplate;

  TimeAwarenessConfig({
    this.enabled = true,
    this.includeCurrentTime = true,
    this.currentTimePromptTemplate = defaultCurrentTimePromptTemplate,
    this.systemGuidePromptTemplate = defaultSystemGuidePromptTemplate,
  });

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'includeCurrentTime': includeCurrentTime,
    'currentTimePromptTemplate': currentTimePromptTemplate,
    'systemGuidePromptTemplate': systemGuidePromptTemplate,
  };

  factory TimeAwarenessConfig.fromJson(Map<String, dynamic> json) {
    return TimeAwarenessConfig(
      // 全局开关已移除，忽略旧存储值
      enabled: true,
      currentTimePromptTemplate:
          json['currentTimePromptTemplate'] as String? ??
          defaultCurrentTimePromptTemplate,
      systemGuidePromptTemplate:
          json['systemGuidePromptTemplate'] as String? ??
          defaultSystemGuidePromptTemplate,
    );
  }

  TimeAwarenessConfig copyWith({
    bool? enabled,
    bool? includeCurrentTime,
    String? currentTimePromptTemplate,
    String? systemGuidePromptTemplate,
  }) {
    return TimeAwarenessConfig(
      enabled: enabled ?? this.enabled,
      includeCurrentTime: includeCurrentTime ?? this.includeCurrentTime,
      currentTimePromptTemplate:
          currentTimePromptTemplate ?? this.currentTimePromptTemplate,
      systemGuidePromptTemplate:
          systemGuidePromptTemplate ?? this.systemGuidePromptTemplate,
    );
  }
}
