import 'message.dart';

/// Explicit topic boundaries must resolve before any raw history is sent.
List<Message> sliceConversationContext(
  List<Message> messages,
  String? boundaryId,
) {
  final boundary = boundaryId?.trim() ?? '';
  if (boundary.isEmpty) return messages;
  final index = messages.lastIndexWhere((message) => message.id == boundary);
  if (index < 0) {
    throw StateError('话题边界已失效，请先恢复或撤销上次压缩，本轮未发送。');
  }
  return messages.sublist(index + 1);
}
