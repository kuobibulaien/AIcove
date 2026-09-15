/// CharacterTextEditorSheet - 角色文本编辑底部弹窗
///
/// 用于角色简介/提示词等长文本编辑，统一复用 MoeBottomSheet 规范。
///
/// 更新记录：
/// - 2026-02-07: 从 ContactEditPage 抽离，统一键盘与返回值处理
library;

import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/form/moe_input_decoration.dart';

import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 修改即时回调；关闭时返回最后一次编辑内容。
Future<String?> showCharacterTextEditorSheet({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String hint,
  ValueChanged<String>? onChanged,
}) async {
  String draft = initialValue;
  final statusBarHeight = MediaQuery.paddingOf(context).top;

  await showMoeBottomSheet<void>(
    context: context,
    title: title,
    showCloseButton: true,
    maxHeight: MediaQuery.sizeOf(context).height - statusBarHeight - 16,
    builder: (sheetContext) {
      return _CharacterTextEditorBody(
        initialValue: initialValue,
        hint: hint,
        onChanged: (value) {
          draft = value;
          onChanged?.call(value);
        },
      );
    },
  );
  return draft;
}

class _CharacterTextEditorBody extends StatefulWidget {
  const _CharacterTextEditorBody({
    required this.initialValue,
    required this.hint,
    required this.onChanged,
  });

  final String initialValue;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_CharacterTextEditorBody> createState() =>
      _CharacterTextEditorBodyState();
}

class _CharacterTextEditorBodyState extends State<_CharacterTextEditorBody> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _controller.addListener(_notifyChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_notifyChanged);
    _controller.dispose();
    super.dispose();
  }

  void _notifyChanged() {
    widget.onChanged(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: MoeG2Decoration(
                radius: 10,
                color: colors.surfaceAlt.withValues(alpha: 0.35),
                border: Border.all(color: colors.borderLight),
              ),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autofocus: true,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: colors.text,
                ),
                decoration: MoeInputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: colors.muted),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
