library;

import 'dart:convert';

import '../../../core/utils/token_estimator.dart';
import '../../context/domain/context_window_policy.dart';

/// 角色完整上下文预览：按当前设置、当前历史装配一次请求但不发送。
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
    this.failed = false,
  });

  final String name;
  final bool injected;
  final String? reason;

  /// [reason] is an exception message rather than a fixed explanation.
  final bool failed;
}

/// 用量组成的分类。
enum ChatContextUsageKind { system, history, toolCalls, toolDefinitions }

/// 一次请求的估算用量：每条消息的 token 与按分类汇总的组成。
class ChatContextUsage {
  const ChatContextUsage({
    required this.messageTokens,
    required this.byKind,
    required this.total,
  });

  /// 按与真实发送相同的口径（[renderedContextTokens]）估算。
  factory ChatContextUsage.measure(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
  ) {
    final byKind = {for (final kind in ChatContextUsageKind.values) kind: 0};
    final messageTokens = <int>[];
    for (final message in messages) {
      final tokens =
          renderedContextTokens([message], const []) - estimateTokenCount('[]');
      messageTokens.add(tokens);
      final kind = kindOf(message);
      byKind[kind] = byKind[kind]! + tokens;
    }
    if (tools.isNotEmpty) {
      byKind[ChatContextUsageKind.toolDefinitions] = estimateTokenCount(
        jsonEncode(tools),
      );
    }
    return ChatContextUsage(
      messageTokens: messageTokens,
      byKind: byKind,
      total: byKind.values.fold(0, (sum, tokens) => sum + tokens),
    );
  }

  final List<int> messageTokens;
  final Map<ChatContextUsageKind, int> byKind;
  final int total;

  static ChatContextUsageKind kindOf(Map<String, dynamic> message) {
    final role = message['role'];
    if (role == 'system') return ChatContextUsageKind.system;
    if (role == 'tool') return ChatContextUsageKind.toolCalls;
    final toolCalls = message['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      return ChatContextUsageKind.toolCalls;
    }
    return ChatContextUsageKind.history;
  }
}
