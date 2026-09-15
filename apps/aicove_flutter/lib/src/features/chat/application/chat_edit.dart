import '../../../core/services/attachment_picker_service.dart';
import '../domain/message.dart';

/// 草稿只持有编辑锚点，不改变持久化历史。提交前必须重新校验版本。
class ChatEditDraft {
  const ChatEditDraft(
      {required this.conversationId,
      required this.messageId,
      required this.historyVersion,
      this.originalMessage});
  final String conversationId;
  final String messageId;
  final String historyVersion;
  // 与version同一DB快照读取，仅准备阶段使用，不写入草稿JSON。
  final Message? originalMessage;

  Map<String, dynamic> toJson() => {
        'conversationId': conversationId,
        'messageId': messageId,
        'historyVersion': historyVersion
      };
  factory ChatEditDraft.fromJson(Map<String, dynamic> json) {
    final owner = json['conversationId'];
    final id = json['messageId'];
    final version = json['historyVersion'];
    if (owner is! String ||
        owner.isEmpty ||
        id is! String ||
        id.isEmpty ||
        version is! String ||
        version.isEmpty) {
      throw const FormatException('编辑草稿标识损坏，请取消编辑后重新选择消息');
    }
    return ChatEditDraft(
        conversationId: owner, messageId: id, historyVersion: version);
  }
}

/// 一次性回填也按会话传递，禁止使用全局文本/附件信箱跨会话回填。
class ChatEditSeed {
  const ChatEditSeed(
      {required this.draft, required this.text, this.attachment});
  final ChatEditDraft draft;
  final String text;
  final SelectedAttachment? attachment;
}

abstract interface class ChatEditPort {
  Future<ChatEditDraft> prepareEdit(String conversationId, String messageId);
  Future<void> commitEdit(ChatEditDraft draft, Message replacement);
}
