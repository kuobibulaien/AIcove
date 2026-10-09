/// MeoTalk 底部弹窗
///
/// 设计特点：
/// - 底部弹出，圆角30
/// - 标题居中，内容居左
/// - 按钮带圆角
library;

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'moe_floating_surface.dart';
import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';

/// MeoTalk 底部弹窗
class MeoTalkDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final String? titleActionText;
  final String? cancelText;
  final String? confirmText;
  final VoidCallback? onTitleAction;
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
    this.titleActionText,
    this.cancelText,
    this.confirmText,
    this.onTitleAction,
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
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Material(
      type: MaterialType.transparency,
      child: AnimatedPadding(
        duration: kAnimFast,
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            child: MoeFloatingSurface(
              baseline: MoeMaterialBaseline.background,
              radius: 30,
              solidColor: colors.componentBackground,
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTitle(colors),
                const SizedBox(height: 16),
                // Keep long content scrollable within the available dialog height.
                Flexible(child: SingleChildScrollView(child: Align(
                  alignment: Alignment.centerLeft,
                  // Merge so content keeps the theme font fallback stack.
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 15,
                      color: colors.textSecondary,
                      height: 1.5,
                    ),
                    child: content,
                  ),
                ))),
                const SizedBox(height: 24),
                // 按钮
                _buildButtons(context, colors),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(MoeColors colors) {
    final hasTitleAction =
        titleActionText?.trim().isNotEmpty == true && onTitleAction != null;

    return SizedBox(
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hasTitleAction ? 56 : 0),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: MoeFontWeights.emphasis,
                color: colors.text,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          if (hasTitleAction)
            Positioned(
              right: 0,
              child: TextButton(
                onPressed: onTitleAction,
                style: withoutHoverFeedback(TextButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  minimumSize: Size.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )),
                child: Text(
                  titleActionText!,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: MoeFontWeights.emphasis,
                    color: colors.textSecondary,
                  ),
                ),
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
                  style: withoutHoverFeedback(TextButton.styleFrom(
                    backgroundColor: colors.surface,
                  )),
                  child: Text(
                    cancelText ?? '取消',
                    style: TextStyle(fontSize: 16, color: colors.text),
                  ),
                ),
              ),
            ),
          ),
        if (showCancelButton && showConfirmButton) const SizedBox(width: 12),
        if (showConfirmButton)
          Expanded(
            child: SizedBox(
              height: 48,
              child: MoeG2ClipRRect(
                radius: buttonRadius,
                child: TextButton(
                  onPressed: onConfirm,
                  style: withoutHoverFeedback(TextButton.styleFrom(
                    backgroundColor: colors.surface,
                  )),
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
  String? titleActionText,
  String? cancelText,
  String? confirmText,
  VoidCallback? onTitleAction,
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
      titleActionText: titleActionText,
      cancelText: cancelText,
      confirmText: confirmText,
      onTitleAction: onTitleAction,
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
