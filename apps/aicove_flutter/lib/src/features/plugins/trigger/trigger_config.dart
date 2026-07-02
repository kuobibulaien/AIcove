import '../../../core/prompts/prompt_builtin_defaults.g.dart';

class TriggerConfig {
  final bool enabled;
  final String logicSystemPrompt;

  /// 废弃的 XML 标签兜底（`<create_trigger>` / `<delete_trigger>`）。
  /// 默认关闭（AR-040）：原生工具调用已是唯一正式入口；
  /// 此灰度开关仅保留一个版本用于回退，之后整体下线。
  final bool xmlFallbackEnabled;

  static const String _defaultLogicPrompt =
      PromptBuiltinDefaults.triggerLogicLegacyDefault;

  const TriggerConfig({
    this.enabled = true,
    this.logicSystemPrompt = _defaultLogicPrompt,
    this.xmlFallbackEnabled = false,
  });

  TriggerConfig copyWith({
    bool? enabled,
    String? logicSystemPrompt,
    bool? xmlFallbackEnabled,
  }) {
    return TriggerConfig(
      enabled: enabled ?? this.enabled,
      logicSystemPrompt: logicSystemPrompt ?? this.logicSystemPrompt,
      xmlFallbackEnabled: xmlFallbackEnabled ?? this.xmlFallbackEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'logic_system_prompt': logicSystemPrompt,
      'xml_fallback_enabled': xmlFallbackEnabled,
    };
  }

  factory TriggerConfig.fromJson(Map<String, dynamic> json) {
    return TriggerConfig(
      enabled: json['enabled'] ?? true,
      logicSystemPrompt: json['logic_system_prompt'] ?? _defaultLogicPrompt,
      xmlFallbackEnabled: json['xml_fallback_enabled'] == true,
    );
  }
}
