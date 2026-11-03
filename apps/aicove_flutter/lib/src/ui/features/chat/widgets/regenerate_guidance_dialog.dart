import 'package:flutter/material.dart';

import '../../../shared/widgets/form/moe_text_field.dart';
import '../../../shared/widgets/meotalk_dialog.dart';

/// 重新生成前询问指导意见。
///
/// 返回 null 表示取消；返回空字符串表示不填意见直接重新生成。
Future<String?> showRegenerateGuidanceDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => const RegenerateGuidanceDialog(),
  );
}

class RegenerateGuidanceDialog extends StatefulWidget {
  const RegenerateGuidanceDialog({super.key});

  @override
  State<RegenerateGuidanceDialog> createState() =>
      _RegenerateGuidanceDialogState();
}

class _RegenerateGuidanceDialogState extends State<RegenerateGuidanceDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return MeoTalkDialog(
      title: '重新生成',
      confirmText: '重新生成',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _confirm,
      content: MoeTextField(
        controller: _controller,
        hint: '可选：希望这次怎么回，例如更简短、换个语气',
        minLines: 2,
        maxLines: 5,
        autofocus: true,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
      ),
    );
  }
}

/// 改词重画：编辑这一页的提示词后重新生成图片。
///
/// 返回 null 表示取消；返回修剪后的非空提示词。
Future<String?> showEditImagePromptDialog(
  BuildContext context, {
  required String initialPrompt,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => EditImagePromptDialog(initialPrompt: initialPrompt),
  );
}

class EditImagePromptDialog extends StatefulWidget {
  const EditImagePromptDialog({super.key, required this.initialPrompt});

  final String initialPrompt;

  @override
  State<EditImagePromptDialog> createState() => _EditImagePromptDialogState();
}

class _EditImagePromptDialogState extends State<EditImagePromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialPrompt,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return MeoTalkDialog(
      title: '改词重画',
      confirmText: '重画',
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _confirm,
      content: MoeTextField(
        controller: _controller,
        hint: '修改这一页的画面描述或台词',
        minLines: 4,
        maxLines: 10,
        autofocus: true,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
      ),
    );
  }
}
