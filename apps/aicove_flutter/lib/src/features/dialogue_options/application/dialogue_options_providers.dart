import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 用户点选的一条对话选项，由输入框按会话接收并填入草稿。
class DialogueOptionPick {
  const DialogueOptionPick({required this.text, required this.signature});

  final String text;

  /// 所属选项组的 [DialogueOptions.signature]；填入成功后标记为已处理。
  final String signature;
}

/// 按会话隔离的投递通道，避免把选项填进其他会话。
final dialogueOptionPickProvider = StateProvider.autoDispose
    .family<DialogueOptionPick?, String>((ref, id) => null);

/// 本次运行中已选用的选项组签名；只存内存，不入历史。
final dialogueOptionsConsumedProvider = StateProvider.family<String?, String>(
  (ref, id) => null,
);
