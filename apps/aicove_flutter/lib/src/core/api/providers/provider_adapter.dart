/// Provider 适配器抽象层
///
/// 职责：统一不同 AI 提供商的 API 调用格式
/// 原则：SOLID - 接口隔离，每个 provider 独立实现
///
/// 更新记录：
/// - 2026-01-27: 添加 tool result 消息构建支持（两回合工具调用）
library;

import 'dart:convert';

import '../thinking/thinking_level.dart';

export '../thinking/thinking_level.dart' show ThinkingLevel, ThinkingScheme;

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

  /// Original argument bytes for transport recovery; business handlers still use arguments.
  final String? rawArguments;
  final String? thoughtSignature;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.rawArguments,
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
      rawArguments: rawArgs is String ? rawArgs : null,
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

/// 只对当前聊天请求生效的供应商参数。
///
/// 这层与渠道的持久化 `customConfig` 分开，用于让 SillyTavern
/// 预设在本轮覆盖模型默认值，同时由各 adapter 转成正确字段名。
class ProviderChatRequestOptions {
  final bool useSystemPrompt;
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? minP;
  final double? topA;
  final double? repetitionPenalty;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final int? seed;
  final int? maxOutputTokens;

  /// Per-request tool policy, never persisted into channel configuration.
  final String? toolChoice;

  /// SillyTavern 预设的原始 `reasoning_effort` 字符串；仅在 [thinkingLevel]
  /// 为空时由 OpenAI 系 adapter 回退使用。
  final String? reasoningEffort;

  /// 已按模型可用集合收敛后的思考档位；null 表示未解析（沿用 [reasoningEffort]）。
  final ThinkingLevel? thinkingLevel;
  final ThinkingScheme? thinkingScheme;

  /// 联网搜索插件接管搜索时为 true：请求体组装后去掉模型内置搜索参数。
  final bool disableBuiltinWebSearch;

  const ProviderChatRequestOptions({
    this.useSystemPrompt = true,
    this.temperature,
    this.topP,
    this.topK,
    this.minP,
    this.topA,
    this.repetitionPenalty,
    this.frequencyPenalty,
    this.presencePenalty,
    this.seed,
    this.maxOutputTokens,
    this.toolChoice,
    this.reasoningEffort,
    this.thinkingLevel,
    this.thinkingScheme,
    this.disableBuiltinWebSearch = false,
  });

  ProviderChatRequestOptions copyWith({
    String? toolChoice,
    ThinkingLevel? thinkingLevel,
    ThinkingScheme? thinkingScheme,
    bool? disableBuiltinWebSearch,
  }) =>
      ProviderChatRequestOptions(
        useSystemPrompt: useSystemPrompt,
        temperature: temperature,
        topP: topP,
        topK: topK,
        minP: minP,
        topA: topA,
        repetitionPenalty: repetitionPenalty,
        frequencyPenalty: frequencyPenalty,
        presencePenalty: presencePenalty,
        seed: seed,
        maxOutputTokens: maxOutputTokens,
        toolChoice: toolChoice ?? this.toolChoice,
        reasoningEffort: reasoningEffort,
        thinkingLevel: thinkingLevel ?? this.thinkingLevel,
        thinkingScheme: thinkingScheme ?? this.thinkingScheme,
        disableBuiltinWebSearch:
            disableBuiltinWebSearch ?? this.disableBuiltinWebSearch,
      );

  Map<String, dynamic> toTraceJson() => <String, dynamic>{
        'useSystemPrompt': useSystemPrompt,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        if (topK != null) 'topK': topK,
        if (minP != null) 'minP': minP,
        if (topA != null) 'topA': topA,
        if (repetitionPenalty != null) 'repetitionPenalty': repetitionPenalty,
        if (frequencyPenalty != null) 'frequencyPenalty': frequencyPenalty,
        if (presencePenalty != null) 'presencePenalty': presencePenalty,
        if (seed != null) 'seed': seed,
        if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
        if (toolChoice != null) 'toolChoice': toolChoice,
        if (reasoningEffort?.isNotEmpty == true)
          'reasoningEffort': reasoningEffort,
        if (thinkingLevel != null) 'thinkingLevel': thinkingLevel!.name,
        if (thinkingScheme != null) 'thinkingScheme': thinkingScheme!.name,
        if (disableBuiltinWebSearch) 'disableBuiltinWebSearch': true,
      };

  List<Map<String, dynamic>> parameterTraceForProvider(String provider) {
    final normalized = provider.trim().toLowerCase();
    final supported = switch (normalized) {
      'claude' => const <String>{
          'temperature',
          'top_p',
          'top_k',
          'max_tokens',
          'thinking_level',
          'use_sysprompt',
        },
      'gemini' => const <String>{
          'temperature',
          'top_p',
          'top_k',
          'frequency_penalty',
          'presence_penalty',
          'seed',
          'max_tokens',
          'thinking_level',
          'use_sysprompt',
        },
      _ => const <String>{
          'temperature',
          'top_p',
          'top_k',
          'min_p',
          'top_a',
          'repetition_penalty',
          'frequency_penalty',
          'presence_penalty',
          'seed',
          'max_tokens',
          'reasoning_effort',
          'thinking_level',
          'use_sysprompt',
        },
    };
    final declared = <String, dynamic>{
      'use_sysprompt': useSystemPrompt,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (topK != null) 'top_k': topK,
      if (minP != null) 'min_p': minP,
      if (topA != null) 'top_a': topA,
      if (repetitionPenalty != null) 'repetition_penalty': repetitionPenalty,
      if (frequencyPenalty != null) 'frequency_penalty': frequencyPenalty,
      if (presencePenalty != null) 'presence_penalty': presencePenalty,
      if (seed != null) 'seed': seed,
      if (maxOutputTokens != null) 'max_tokens': maxOutputTokens,
      if (reasoningEffort?.isNotEmpty == true)
        'reasoning_effort': reasoningEffort,
      if (thinkingLevel != null) 'thinking_level': thinkingLevel!.name,
    };
    bool isDefault(String field, dynamic value) => switch (field) {
          'top_k' || 'min_p' || 'top_a' => value == 0,
          'repetition_penalty' => value == 1,
          'frequency_penalty' || 'presence_penalty' => value == 0,
          'seed' => value is int && value < 0,
          'reasoning_effort' => value == 'auto' || value == '' || thinkingLevel != null,
          'thinking_level' => value == 'auto',
          _ => false,
        };
    return <Map<String, dynamic>>[
      for (final entry in declared.entries)
        <String, dynamic>{
          'field': entry.key,
          'value': entry.value,
          'status': isDefault(entry.key, entry.value)
              ? 'notApplicable'
              : supported.contains(entry.key)
                  ? 'applied'
                  : 'intentionallyUnsupported',
          'reason': isDefault(entry.key, entry.value)
              ? 'default_value_omitted'
              : supported.contains(entry.key)
                  ? 'emitted_to_$normalized'
                  : 'not_supported_by_$normalized',
        },
    ];
  }
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
    ProviderChatRequestOptions? requestOptions,
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
