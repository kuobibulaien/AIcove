/// LLM 钩子类型
enum LLMHookType {
  /// LLM 请求前（可修改请求内容）
  beforeRequest,

  /// LLM 响应后（可查看响应内容）
  afterResponse,
}

/// LLM 钩子
/// 在 LLM 请求/响应的关键节点介入处理
class LLMHook {
  /// 钩子类型
  final LLMHookType type;

  /// 钩子处理函数
  /// beforeRequest 时，context 是请求对象，可修改
  /// afterResponse 时，context 是响应对象，只读
  final Future<void> Function(dynamic context) handler;

  const LLMHook({
    required this.type,
    required this.handler,
  });
}
