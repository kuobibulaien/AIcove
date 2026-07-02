import '../plugins/domain/index.dart';
import '../plugins/plugin_manager.dart';

/// AI 工具提供者类型
enum AIProvider {
  openai,
  anthropic,
  custom,
}

/// AI 工具收集器
/// 负责从插件管理器收集工具，并转换为不同 LLM 提供商的格式
class AIToolCollector {
  final PluginManager pluginManager;

  AIToolCollector(this.pluginManager);

  /// 获取所有启用插件的 AI 工具
  List<AITool> getAllTools() {
    return pluginManager.getAllTools();
  }

  /// 转换为 OpenAI Function Calling 格式
  List<Map<String, dynamic>> toOpenAIFormat() {
    final tools = getAllTools();
    return tools.map((tool) => tool.toOpenAISchema()).toList();
  }

  /// 转换为 Anthropic Tool 格式
  List<Map<String, dynamic>> toAnthropicFormat() {
    final tools = getAllTools();
    return tools.map((tool) => tool.toAnthropicSchema()).toList();
  }

  /// 根据提供商类型自动选择格式
  List<Map<String, dynamic>> toFormat(AIProvider provider) {
    switch (provider) {
      case AIProvider.openai:
        return toOpenAIFormat();
      case AIProvider.anthropic:
        return toAnthropicFormat();
      case AIProvider.custom:
        return toOpenAIFormat(); // 默认使用 OpenAI 格式
    }
  }

  /// 执行工具调用
  /// 根据工具名称和参数，找到对应的 AITool 并执行
  Future<String?> executeTool(String toolName, Map<String, dynamic> arguments) async {
    final tools = getAllTools();
    final tool = tools.where((t) => t.name == toolName).firstOrNull;

    if (tool == null) {
      throw Exception('工具不存在: $toolName');
    }

    try {
      return await tool.handler(arguments);
    } catch (e) {
      throw Exception('工具执行失败: $e');
    }
  }

  /// 批量执行工具调用
  Future<List<ToolCallResult>> executeTools(List<ToolCallRequest> requests) async {
    final results = <ToolCallResult>[];

    for (final request in requests) {
      try {
        final result = await executeTool(request.name, request.arguments);
        results.add(ToolCallResult(
          toolName: request.name,
          callId: request.callId,
          success: true,
          result: result,
        ));
      } catch (e) {
        results.add(ToolCallResult(
          toolName: request.name,
          callId: request.callId,
          success: false,
          error: e.toString(),
        ));
      }
    }

    return results;
  }
}

/// 工具调用请求
class ToolCallRequest {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCallRequest({
    required this.callId,
    required this.name,
    required this.arguments,
  });

  factory ToolCallRequest.fromOpenAI(Map<String, dynamic> json) {
    return ToolCallRequest(
      callId: json['id'] as String,
      name: json['function']['name'] as String,
      arguments: json['function']['arguments'] as Map<String, dynamic>,
    );
  }

  factory ToolCallRequest.fromAnthropic(Map<String, dynamic> json) {
    return ToolCallRequest(
      callId: json['id'] as String,
      name: json['name'] as String,
      arguments: json['input'] as Map<String, dynamic>,
    );
  }
}

/// 工具调用结果
class ToolCallResult {
  final String toolName;
  final String callId;
  final bool success;
  final String? result;
  final String? error;

  const ToolCallResult({
    required this.toolName,
    required this.callId,
    required this.success,
    this.result,
    this.error,
  });

  /// 转为 OpenAI 格式的 tool message
  Map<String, dynamic> toOpenAIMessage() {
    return {
      'role': 'tool',
      'tool_call_id': callId,
      'content': success ? (result ?? '') : 'Error: $error',
    };
  }

  /// 转为 Anthropic 格式的 tool result
  Map<String, dynamic> toAnthropicResult() {
    return {
      'type': 'tool_result',
      'tool_use_id': callId,
      'content': success ? (result ?? '') : 'Error: $error',
      if (!success) 'is_error': true,
    };
  }
}
