/// 会话状态（MVU 变量等）的读取端口（ADR0071）。
///
/// 状态 = 冻结的初始化基线 + 沿当前消息链重放原始回复里的更新块；
/// 逐条快照只是可自愈的缓存。宏装配、发送后的刷新与状态面板都只经此端口。
library;

import 'mvu_engine.dart';

/// 初始化所需的来源快照；一次请求内固定。
class MvuSourceSnapshot {
  const MvuSourceSnapshot({required this.sources, this.expandMacros});

  final List<MvuInitSource> sources;
  final String Function(String text)? expandMacros;
}

class ConversationStateView {
  const ConversationStateView({
    required this.active,
    this.mvu,
    this.anchorMessageId,
    this.status = '',
    this.diagnostics = const <String>[],
  });

  const ConversationStateView.inactive({this.diagnostics = const <String>[]})
    : active = false,
      mvu = null,
      anchorMessageId = null,
      status = '';

  /// MVU 在本会话生效（会话用上的酒馆预设——角色绑定或默认预设——没关 MVU，且初始化成功）。
  final bool active;
  final MvuState? mvu;

  /// 状态所在的最后一条 AI 消息；null 表示还停在基线。
  final String? anchorMessageId;

  /// 最近一步的状态（`applied` / `partial` / `no_ops` / `parse_error` / `ready`）。
  final String status;
  final List<String> diagnostics;
}

abstract interface class ConversationStatePort {
  /// 读取当前消息链末尾的状态，必要时初始化并补算缺失或失效的缓存。
  /// [sources] 为 null 时由实现自行解析来源；解析结果为 MVU 未启用时返回 inactive。
  Future<ConversationStateView> read(
    String conversationId, {
    MvuSourceSnapshot? sources,
  });

  /// 新回复落库后把状态算到链尾；失败只记日志，不影响聊天。
  Future<void> refresh(String conversationId);
}
