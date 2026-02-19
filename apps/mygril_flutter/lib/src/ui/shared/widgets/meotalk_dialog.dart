/// MeoTalk 底部弹窗
///
/// 设计特点：
/// - 底部弹出，圆角30
/// - 标题居中，内容居左
/// - 按钮带圆角
library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';

/// MeoTalk 底部弹窗
class MeoTalkDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final String? cancelText;
  final String? confirmText;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final bool showCancelButton;
  final bool showConfirmButton;
  final bool barrierDismissible;
  final bool isDanger;

  const MeoTalkDialog({
    super.key,
    required this.title,
    required this.content,
    this.cancelText,
    this.confirmText,
    this.onCancel,
    this.onConfirm,
    this.showCancelButton = true,
    this.showConfirmButton = true,
    this.barrierDismissible = true,
    this.isDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            decoration: MoeG2Decoration(
              radius: 30,
              color: colors.componentBackground,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题居中
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.text,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // 内容居左
                Align(
                  alignment: Alignment.centerLeft,
                  child: DefaultTextStyle(
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.textSecondary,
                      height: 1.5,
                    ),
                    child: content,
                  ),
                ),
                const SizedBox(height: 24),
                // 按钮
                _buildButtons(context, colors),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButtons(BuildContext context, MoeColors colors) {
    if (!showCancelButton && !showConfirmButton) {
      return const SizedBox.shrink();
    }

    const buttonRadius = 12.0;

    return Row(
      children: [
        if (showCancelButton)
          Expanded(
            child: SizedBox(
              height: 48,
              child: MoeG2ClipRRect(
                radius: buttonRadius,
                child: TextButton(
                  onPressed: onCancel ?? () => Navigator.of(context).pop(false),
                  style: TextButton.styleFrom(
                    backgroundColor: colors.surface,
                  ),
                  child: Text(
                    cancelText ?? '取消',
                    style: TextStyle(fontSize: 16, color: colors.text),
                  ),
                ),
              ),
            ),
          ),
        if (showCancelButton && showConfirmButton)
          const SizedBox(width: 12),
        if (showConfirmButton)
          Expanded(
            child: SizedBox(
              height: 48,
              child: MoeG2ClipRRect(
                radius: buttonRadius,
                child: TextButton(
                  onPressed: onConfirm,
                  style: TextButton.styleFrom(
                    backgroundColor: colors.surface,
                  ),
                  child: Text(
                    confirmText ?? '确认',
                    style: TextStyle(
                      fontSize: 16,
                      color: isDanger ? Colors.red : colors.accentColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 显示 MeoTalk 底部弹窗
Future<bool?> showMeoTalkDialog({
  required BuildContext context,
  required String title,
  required Widget content,
  String? cancelText,
  String? confirmText,
  bool showCancelButton = true,
  bool showConfirmButton = true,
  bool barrierDismissible = true,
  bool isDanger = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.transparent,
    builder: (context) => MeoTalkDialog(
      title: title,
      content: content,
      cancelText: cancelText,
      confirmText: confirmText,
      showCancelButton: showCancelButton,
      showConfirmButton: showConfirmButton,
      barrierDismissible: barrierDismissible,
      isDanger: isDanger,
      onCancel: () => Navigator.of(context).pop(false),
      onConfirm: () => Navigator.of(context).pop(true),
    ),
  );
}

/// 显示带简单文本内容的确认弹窗
Future<bool?> showMeoTalkConfirm({
  required BuildContext context,
  required String title,
  required String message,
  String? hint,
  String? cancelText,
  String? confirmText,
  bool isDanger = false,
}) {
  final colors = context.moeColors;

  return showMeoTalkDialog(
    context: context,
    title: title,
    isDanger: isDanger,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(
            fontSize: 15,
            color: colors.textSecondary,
            height: 1.5,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(
              fontSize: 13,
              color: colors.muted,
              height: 1.4,
            ),
          ),
        ],
      ],
    ),
    cancelText: cancelText,
    confirmText: confirmText,
  );
}

/// 显示纯信息弹窗（只有确认按钮）
Future<void> showMeoTalkAlert({
  required BuildContext context,
  required String title,
  required String message,
  String? confirmText,
}) {
  return showMeoTalkDialog(
    context: context,
    title: title,
    content: Text(message),
    showCancelButton: false,
    confirmText: confirmText ?? '知道了',
  );
}
