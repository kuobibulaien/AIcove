import '../../../../core/models/message_block.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/voice_call/application/active_voice_call.dart';

/// 通话进行中，把逐句记录投影成聊天列表里的临时气泡（只是显示）。
///
/// 这些消息不写库、不进主对话上下文；挂断后它们随通话记录收进同一条通话气泡，
/// 聊天页随之撤掉临时显示。id 带固定前缀，长按菜单据此不给编辑和重新生成；
/// 删除只把这一句从显示里拿掉（[ActiveVoiceCall.hideTurn]），通话记录不变。
List<Message> voiceCallLiveMessages(ActiveVoiceCall call) {
  final base = call.startedAt;
  final prefix = '$voiceCallLiveMessagePrefix${base.microsecondsSinceEpoch}_';
  return [
    for (final (index, turn) in call.transcript.indexed)
      if (turn.spokenText.isNotEmpty && !call.isTurnHidden(index))
        _message(
          id: '$prefix$index',
          role: turn.role,
          text: turn.interrupted ? '${turn.spokenText}……' : turn.spokenText,
          // 排在已有消息之后，并保持说话顺序。
          createdAt: base.add(Duration(milliseconds: index)),
        ),
  ];
}

const voiceCallLiveMessagePrefix = 'voice_call_live_';

/// 临时气泡对应的逐句记录序号；不是通话临时气泡时返回 null。
int? voiceCallLiveTurnIndex(String messageId) {
  if (!messageId.startsWith(voiceCallLiveMessagePrefix)) return null;
  return int.tryParse(messageId.substring(messageId.lastIndexOf('_') + 1));
}

Message _message({
  required String id,
  required String role,
  required String text,
  required DateTime createdAt,
}) => Message(
  id: id,
  role: role,
  content: text,
  blocks: [TextBlock(messageId: id, content: text)],
  createdAt: createdAt,
  status: 'sent',
);
