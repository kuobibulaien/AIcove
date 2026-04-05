/// Provider 适配器抽象层
///
/// 职责：统一不同 AI 提供商的 API 调用格式
/// 原则：SOLID - 接口隔离，每个 provider 独立实现
///
/// 更新记录：
/// - 2026-01-27: 添加 tool result 消息构建支持（两回合工具调用）
library;

import 'dart:convert';

/// API 调用结果
class ApiCallResult {
  final String text;
  final List<Map<String, dynamic>> toolResults;
  final List<ToolCall> toolCalls;
  final List<Map<String, dynamic>> hiddenThoughtParts;
  final Map<String, dynamic>? rawResponse;

  const ApiCallResult({
    required this.text,
    this.toolResults = const [],
    this.toolCalls = const [],
    this.hiddenThoughtParts = const [],
    this.rawResponse,
  });

  /// 是否包含工具调用请求
  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 工具调用请求（AI 返回的）
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String? thoughtSignature;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
  });

  factory ToolCall.fromOpenAI(Map<String, dynamic> json) {
    final function = json['function'] as Map<String, dynamic>? ?? {};
    final rawArgs = function['arguments'];
    Map<String, dynamic> args = {};

    if (rawArgs is Map<String, dynamic>) {
      args = Map<String, dynamic>.from(rawArgs);
    } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map<String, dynamic>) {
          args = decoded;
        }
      } catch (_) {
        args = {};
      }
    }

    return ToolCall(
      id: json['id']?.toString() ?? '',
      name: function['name']?.toString() ?? '',
      arguments: args,
      thoughtSignature: json['thoughtSignature']?.toString() ??
          json['thought_signature']?.toString(),
    );
  }

  /// 转换为 OpenAI 格式（用于追加到 messages）
  Map<String, dynamic> toOpenAIFormat() {
    return {
      'id': id,
      'type': 'function',
      'function': {
        'name': name,
        'arguments': jsonEncode(arguments),
      },
    };
  }
}

/// 工具执行结果
class ToolResult {
  final String toolCallId;
  final String name;
  final String result;

  const ToolResult({
    required this.toolCallId,
    required this.name,
    required this.result,
  });
}

/// Provider 适配器抽象接口
abstract class ProviderAdapter {
  /// 构建请求端点 URL
  String buildEndpoint(String baseUrl, {required String modelType});

  /// 构建请求头
  Map<String, String> buildHeaders(String apiKey);

  /// 构建请求体
  /// [tools] 工具定义列表（OpenAI 格式）
  /// [topP] 核采样参数（null 时不发送，由服务商使用默认值）
  Map<String, dynamic> buildRequestBody({
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    double? topP,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
  });

  /// 解析响应
  ApiCallResult parseResponse(Map<String, dynamic> response);

  /// 获取适配器名称
  String get name;

  /// 构建包含工具调用结果的消息（用于两回合工具调用）
  ///
  /// [assistantMessage] AI 的原始响应（包含 tool_calls）
  /// [toolResults] 工具执行结果列表
  ///
  /// 返回应追加到 messages 的消息列表（assistant + tool results）
  List<Map<String, dynamic>> buildToolResultMessages({
    required Map<String, dynamic> assistantMessage,
    required List<ToolResult> toolResults,
  });
}
