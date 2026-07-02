import 'tool_parameter.dart';

/// AI 工具（用于 Function Calling）
/// 定义 AI 可以调用的工具
class AITool {
  /// 工具名称（供 AI 调用，如 "search_weather"）
  final String name;

  /// 工具描述（告诉 AI 这个工具是干什么的）
  final String description;

  /// 参数定义
  final Map<String, ToolParameter> parameters;

  /// 工具执行函数
  /// 参数：AI 传入的参数（键值对）
  /// 返回：执行结果（会传回给 AI）
  final Future<String?> Function(Map<String, dynamic> args) handler;

  const AITool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
  });

  /// 转为 OpenAI Function Calling 格式
  Map<String, dynamic> toOpenAISchema() {
    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final entry in parameters.entries) {
      properties[entry.key] = entry.value.toJsonSchema();
      if (entry.value.required) {
        required.add(entry.key);
      }
    }

    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      },
    };
  }

  /// 转为 Anthropic Tool 格式
  Map<String, dynamic> toAnthropicSchema() {
    final properties = <String, dynamic>{};
    final required = <String>[];

    for (final entry in parameters.entries) {
      properties[entry.key] = entry.value.toJsonSchema();
      if (entry.value.required) {
        required.add(entry.key);
      }
    }

    return {
      'name': name,
      'description': description,
      'input_schema': {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      },
    };
  }
}
