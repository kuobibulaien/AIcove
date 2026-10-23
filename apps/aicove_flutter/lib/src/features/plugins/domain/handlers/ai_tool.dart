import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ToolEffect, KernelCancellation, KernelStopReason;
import 'tool_parameter.dart';
import 'tool_output.dart';
export 'tool_output.dart';

enum ToolExposure { direct, codemode, deferred }

/// AI 工具（用于 Function Calling）
/// 定义 AI 可以调用的工具
class AITool {
  /// 工具名称（供 AI 调用，如 "search_weather"）
  final String name;
  final ToolExposure exposure;
  final Map<String, dynamic>? outputSchema;
  final String? namespace;

  /// 工具描述（告诉 AI 这个工具是干什么的）
  final String description;

  /// 参数定义
  final Map<String, ToolParameter> parameters;

  /// 工具执行函数
  /// 参数：AI 传入的参数（键值对）
  /// 返回：执行结果（会传回给 AI）
  final Future<String?> Function(Map<String, dynamic> args) handler;

  /// 完整的参数 JSON Schema（外部工具如 MCP 自带）；非空时取代 [parameters]。
  final Map<String, dynamic>? inputSchema;

  /// Original schema when a provider-facing projection drops keywords.
  /// Execution validation must not inherit transport compatibility losses.
  final Map<String, dynamic>? validationSchema;

  final Future<ToolOutput> Function(Map<String, dynamic> args)? richHandler;

  /// Optional cooperative handler. Existing one-argument handlers keep their
  /// contract; cancellable tools receive the request-local signal/progress.
  final Future<ToolOutput> Function(
    Map<String, dynamic> args,
    ToolExecutionControl control,
  )?
  controlledHandler;

  /// A self-managed deadline: the handler must stop and settle before returning.
  final Duration? executionTimeout;
  final bool managesDeadline;

  /// This call needs explicit human consent, regardless of risk defaults.
  final bool requiresHumanApproval;

  final KernelStopReason? terminationReason;

  /// May run alongside other concurrent or read-only calls of one batch,
  /// like Pi's per-tool `executionMode: "parallel"` (ADR0110).
  final bool concurrent;

  Future<ToolOutput> invoke(Map<String, dynamic> args) async =>
      controlledHandler != null
      ? controlledHandler!(
          args,
          ToolExecutionControl(
            cancellation: ToolCallContext.current?.cancellation,
            onProgress: ToolCallContext.current?.onProgress,
          ),
        )
      : richHandler != null
      ? richHandler!(args)
      : ToolOutput(text: await handler(args) ?? '');

  /// 工具效果，授权闸门据此判断（第二批方案 3.4）；未声明按对外副作用处理。
  final ToolEffect effect;

  const AITool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.handler,
    this.inputSchema,
    this.exposure = ToolExposure.direct,
    this.outputSchema,
    this.namespace,
    this.validationSchema,
    this.richHandler,
    this.controlledHandler,
    this.executionTimeout,
    this.managesDeadline = false,
    this.requiresHumanApproval = false,
    this.terminationReason,
    this.effect = ToolEffect.external,
    this.concurrent = false,
  });

  Map<String, dynamic> get parameterSchema =>
      inputSchema ??
      {
        'type': 'object',
        'properties': {
          for (final e in parameters.entries) e.key: e.value.toJsonSchema(),
        },
        'required': [
          for (final e in parameters.entries)
            if (e.value.required) e.key,
        ],
      };

  AITool copyWith({
    String? name,
    String? description,
    ToolExposure? exposure,
    Map<String, dynamic>? inputSchema,
    Map<String, dynamic>? outputSchema,
    String? namespace,
  }) => AITool(
    name: name ?? this.name,
    description: description ?? this.description,
    exposure: exposure ?? this.exposure,
    parameters: parameters,
    handler: handler,
    inputSchema: inputSchema ?? this.inputSchema,
    outputSchema: outputSchema ?? this.outputSchema,
    namespace: namespace ?? this.namespace,
    validationSchema: validationSchema,
    richHandler: richHandler,
    controlledHandler: controlledHandler,
    executionTimeout: executionTimeout,
    managesDeadline: managesDeadline,
    requiresHumanApproval: requiresHumanApproval,
    terminationReason: terminationReason,
    effect: effect,
    concurrent: concurrent,
  );

  /// 转为 OpenAI Function Calling 格式
  Map<String, dynamic> toOpenAISchema() {
    if (inputSchema != null) {
      return {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': inputSchema,
        },
      };
    }
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
    if (inputSchema != null) {
      return {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
    }
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

/// Who is calling a tool. The runner sets it around every handler call, so
/// a handler can tell runs, rounds and calls apart without new arguments.
class ToolCallContext {
  const ToolCallContext({
    required this.sessionId,
    required this.turnId,
    required this.round,
    required this.toolCallId,
    this.isCancelled,
    this.cancellation,
    this.onProgress,
    this.scriptTools,
    this.stateOwner,
  });

  static const _key = #aicoveToolCallContext;

  /// Null outside a runner (tests calling a handler directly).
  static ToolCallContext? get current => Zone.current[_key] as ToolCallContext?;

  final String sessionId;
  final String turnId;
  final int round;

  /// As the provider gave it; not unique across conversations or runs.
  final String toolCallId;
  final bool Function()? isCancelled;
  final KernelCancellation? cancellation;
  final void Function(String)? onProgress;
  final ScriptToolAccess? scriptTools;
  final String? stateOwner;

  Future<T> run<T>(Future<T> Function() body) =>
      runZoned(body, zoneValues: {_key: this});
}

class ToolExecutionControl {
  const ToolExecutionControl({this.cancellation, this.onProgress});
  final KernelCancellation? cancellation;
  final void Function(String)? onProgress;
  void progress(String text) {
    cancellation?.throwIfCancelled();
    onProgress?.call(text);
  }
}

/// Supplied only by the kernel; scripts cannot invoke raw handlers or approvals.
class ScriptToolAccess {
  const ScriptToolAccess(this.tools, this.invoke, {this.invokeControlled});
  final List<AITool> tools;
  final Future<ToolOutput> Function(
    String,
    Map<String, dynamic>,
    bool Function(),
    KernelCancellation,
    String,
  )?
  invokeControlled;
  Future<ToolOutput> execute(
    String name,
    Map<String, dynamic> args,
    bool Function() active, {
    required KernelCancellation cancellation,
    required String callId,
  }) =>
      invokeControlled?.call(name, args, active, cancellation, callId) ??
      invoke(name, args, active);
  final Future<ToolOutput> Function(
    String name,
    Map<String, dynamic> arguments,
    bool Function() isActive,
  )
  invoke;
}
