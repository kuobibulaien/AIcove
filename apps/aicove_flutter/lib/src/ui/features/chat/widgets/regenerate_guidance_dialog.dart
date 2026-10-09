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
        helperText: '不填也可以，直接重新生成；意见只用于本次，不会保存到聊天记录',
        minLines: 2,
        maxLines: 5,
        autofocus: true,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
      ),
    );
  }
}
