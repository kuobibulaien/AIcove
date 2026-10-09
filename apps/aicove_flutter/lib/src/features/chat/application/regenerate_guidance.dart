import '../../../core/models/message_block.dart';
import '../domain/message.dart';

/// 规整用户填写的重新生成指导意见；空白视为未填写。
String? normalizeRegenerateGuidance(String? guidance) {
  final trimmed = guidance?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// 把指导意见追加到本次请求里的源用户消息末尾。
///
/// 只改请求用的历史副本，不写回存储；用户消息找不到时原样返回。
List<Message> applyRegenerateGuidance(
  List<Message> history, {
  required String userMessageId,
  required String? guidance,
}) {
  final normalized = normalizeRegenerateGuidance(guidance);
  if (normalized == null) return history;
  final index = history.lastIndexWhere((m) => m.id == userMessageId);
  if (index < 0) return history;

  final note = '【本次回复要求】$normalized\n（请直接体现在回复中，不要提及这条要求）';
  final original = history[index];
  final blocks = original.blocks;
  final guided = blocks == null || blocks.isEmpty
      ? original.copyWith(content: '${original.content}\n\n$note')
      : original.copyWith(
          blocks: [
            ...blocks,
            TextBlock(messageId: original.id, content: note),
          ],
        );
  return [...history]..[index] = guided;
}
