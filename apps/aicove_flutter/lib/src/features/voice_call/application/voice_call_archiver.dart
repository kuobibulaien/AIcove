import 'dart:async';

import '../../../core/models/message_block.dart';
import '../../chat/domain/message.dart';
import '../domain/voice_call_ports.dart';

/// 挂断后存档：聊天里追加一条通话气泡，逐句记录作为气泡的附属数据一起存、
/// 一起同步（ADR0074 决定 3）；再在后台整理摘要补进气泡，之后的文字聊天
/// 只看到摘要（决定 4）。
class VoiceCallArchiver {
  VoiceCallArchiver({
    required this.appendBubble,
    required this.newId,
    this.summarize,
    this.attachSummary,
    this.appendAssistantBubble,
    void Function(Future<void> task)? runInBackground,
    void Function(String message)? log,
    DateTime Function()? now,
  }) : _runInBackground = runInBackground ?? unawaited,
       _log = log ?? ((_) {}),
       _now = now ?? DateTime.now;

  /// 把气泡消息写进聊天记录（不触发回复）。
  final Future<void> Function(String conversationId, Message bubble)
  appendBubble;
  final String Function(String prefix) newId;

  /// 以角色的名义写一条气泡（未接来电用）。
  final Future<void> Function(String conversationId, Message bubble)?
  appendAssistantBubble;

  /// 整理通话摘要；返回空表示没什么可记的。
  final Future<String?> Function(String conversationId, List<CallTurn> turns)?
  summarize;

  /// 把摘要补进仍然有效的那条通话气泡；气泡已删、被编辑或已不是这通电话时
  /// 不写，返回 false。不改会话预览和时间。
  final Future<bool> Function({
    required String conversationId,
    required String messageId,
    required String callId,
    required String summary,
  })?
  attachSummary;
  final void Function(Future<void> task) _runInBackground;
  final void Function(String message) _log;
  final DateTime Function() _now;

  /// 角色主动打来、用户没接：以角色的名义留一条未接来电气泡，不整理摘要。
  /// 气泡编号由 [key]（来电触发器）推出，重复写入只覆盖同一条。
  /// [appendAssistantBubble] 为空时不记录。
  Future<CallRecordBlock?> archiveMissed(
    String conversationId, {
    required String key,
    DateTime? at,
  }) async {
    final append = appendAssistantBubble;
    if (append == null) return null;
    final messageId = 'call_msg_missed_$key';
    final block = CallRecordBlock.missed(
      messageId: messageId,
      callId: 'call_missed_$key',
    );
    await append(
      conversationId,
      Message(
        id: messageId,
        role: 'assistant',
        content: block.content,
        blocks: [block],
        createdAt: at ?? _now(),
        status: 'sent',
      ),
    );
    return block;
  }

  /// 没接通（[connectedAt] 为 null）的电话不留记录。
  Future<CallRecordBlock?> archive({
    required String conversationId,
    required DateTime? connectedAt,
    required List<CallTurn> turns,
  }) async {
    if (connectedAt == null) return null;
    final endedAt = _now();
    final callId = newId('call');
    final messageId = newId('call_msg');
    final block = CallRecordBlock(
      messageId: messageId,
      callId: callId,
      duration: endedAt.difference(connectedAt),
      turns: turns,
    );
    final bubble = Message(
      id: messageId,
      role: 'user',
      content: block.content,
      blocks: [block],
      createdAt: endedAt,
      status: 'sent',
    );
    await appendBubble(conversationId, bubble);
    if (turns.any((turn) => turn.isUser && turn.text.trim().isNotEmpty)) {
      _runInBackground(_attachSummary(conversationId, block, turns));
    }
    return block;
  }

  /// 摘要失败只记日志：气泡照常显示，之后的文字聊天只知道打过电话。
  Future<void> _attachSummary(
    String conversationId,
    CallRecordBlock block,
    List<CallTurn> turns,
  ) async {
    final summarize = this.summarize;
    final attachSummary = this.attachSummary;
    if (summarize == null || attachSummary == null) return;
    try {
      final summary = (await summarize(conversationId, turns))?.trim() ?? '';
      if (summary.isEmpty) return;
      final written = await attachSummary(
        conversationId: conversationId,
        messageId: block.messageId,
        callId: block.callId,
        summary: summary,
      );
      _log(written ? '通话摘要已写入：${summary.length} 字' : '通话气泡已删除或改动，摘要不再写入');
    } catch (e) {
      _log('通话摘要整理失败：${e.runtimeType}');
    }
  }
}
