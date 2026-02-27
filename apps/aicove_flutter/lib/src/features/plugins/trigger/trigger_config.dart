class TriggerConfig {
  final bool enabled;
  final String logicSystemPrompt;

  static const String _defaultLogicPrompt = '''
You are a personal schedule manager.
Analyze the chat history and extract triggers.
Output JSON format:
{
  "triggers": [
    {
      "title": "Task Name",
      "time": "ISO8601",
      "priority": "high|medium|low",
      "prompt": "System instruction for AI when triggering",
      "cached_content": "Pre-generated message content (optional)"
    }
  ]
}
Rules:
1. High Priority: Explicit alarms/reminders.
2. Medium Priority: Contextual tasks.
3. Low Priority: Proactive engagement.
''';

  const TriggerConfig({
    this.enabled = true,
    this.logicSystemPrompt = _defaultLogicPrompt,
  });

  TriggerConfig copyWith({
    bool? enabled,
    String? logicSystemPrompt,
  }) {
    return TriggerConfig(
      enabled: enabled ?? this.enabled,
      logicSystemPrompt: logicSystemPrompt ?? this.logicSystemPrompt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'logic_system_prompt': logicSystemPrompt,
    };
  }

  factory TriggerConfig.fromJson(Map<String, dynamic> json) {
    return TriggerConfig(
      enabled: json['enabled'] ?? true,
      logicSystemPrompt: json['logic_system_prompt'] ?? _defaultLogicPrompt,
    );
  }
}
