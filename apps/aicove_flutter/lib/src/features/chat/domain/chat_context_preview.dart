library;

/// 联系人上下文预览：按当前设置、当前历史装配一次请求但不发送。
///
/// 与真实发送共用 `ChatSendBackendService` 的装配链路，只跳过会写数据或
/// 调用模型的步骤（补摘要、自动压缩、会话变量写回、追踪落盘）。
class ChatContextPreview {
  const ChatContextPreview({
    required this.modelId,
    required this.presetName,
    required this.messages,
    required this.messageTokens,
    required this.tools,
    required this.sources,
    required this.plugins,
    required this.inputTokens,
    required this.inputLimit,
    required this.notes,
  });

  /// 实际请求使用的模型。
  final String modelId;

  /// 绑定的酒馆预设名；未绑定为 null。
  final String? presetName;

  /// 最终发给模型的消息，顺序与真实请求一致。
  final List<Map<String, dynamic>> messages;

  /// 与 [messages] 一一对应的估算 token。
  final List<int> messageTokens;

  /// 发给模型的工具定义（OpenAI 结构）。
  final List<Map<String, dynamic>> tools;

  /// 系统提示词的来源拆分，按装配顺序。
  final List<ChatContextSource> sources;

  /// 每个插件的提示词注入结果，包括未注入的原因。
  final List<ChatContextPluginStatus> plugins;

  /// 估算输入 token（消息＋工具）。
  final int inputTokens;

  /// 自动压缩阈值；达到后真实发送会先压缩。
  final int inputLimit;

  /// 预览与真实发送可能不同之处的说明，以及预设告警。
  final List<String> notes;
}

class ChatContextSource {
  const ChatContextSource({required this.label, required this.content});

  final String label;
  final String content;
}

class ChatContextPluginStatus {
  const ChatContextPluginStatus({
    required this.name,
    required this.injected,
    this.reason,
  });

  final String name;
  final bool injected;
  final String? reason;
}
