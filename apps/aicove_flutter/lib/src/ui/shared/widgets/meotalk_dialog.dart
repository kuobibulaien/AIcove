/// MeoTalk 弹窗
///
/// 设计特点：
/// - 默认底部弹出，圆角30；`centered` 时居中显示，宽度封顶 420，圆角24
/// - 标题居中，内容居左
/// - 按钮带圆角
library;

import 'package:aicove_flutter/src/ui/theme/moe_interaction_theme.dart';
import 'package:flutter/material.dart';
import 'buttons/moe_primary_button.dart';
import 'buttons/moe_secondary_button.dart';
import 'moe_floating_surface.dart';
import '../../theme/tokens.dart';

/// MeoTalk 弹窗（默认底部，`centered` 居中）
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

  /// 居中显示，用于桌面端窗口级询问等不跟随底部操作区的场景。
  final bool centered;

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
    this.centered = false,
  });

  /// 居中弹窗的最大宽度
  static const double centeredMaxWidth = 420;

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
          alignment: centered ? Alignment.center : Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            constraints: centered
                ? const BoxConstraints(maxWidth: centeredMaxWidth)
                : null,
            margin: const EdgeInsets.all(16),
            child: MoeFloatingSurface(
              baseline: MoeMaterialBaseline.background,
              radius: centered ? 24 : 30,
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

    const buttonRadius = BorderRadius.all(Radius.circular(12));

    return Row(
      children: [
        if (showCancelButton)
          Expanded(
            child: MoeSecondaryButton(
              label: cancelText ?? '取消',
              borderRadius: buttonRadius,
              onPressed: onCancel ?? () => Navigator.of(context).pop(false),
            ),
          ),
        if (showCancelButton && showConfirmButton) const SizedBox(width: 12),
        if (showConfirmButton)
          Expanded(
            child: MoePrimaryButton(
              label: confirmText ?? '确认',
              borderRadius: buttonRadius,
              backgroundColor: isDanger ? colors.toastError : colors.accentColor,
              // Danger keeps the error color on its label; normal confirms
              // use the theme text color for readability on the accent tint.
              foregroundColor: isDanger ? colors.toastError : null,
              onPressed: onConfirm,
            ),
          ),
      ],
    );
  }
}

/// 显示 MeoTalk 弹窗（默认底部，`centered` 居中）
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
  bool useRootNavigator = true,
  bool centered = false,
}) {
  return showDialog<bool>(
    context: context,
    useRootNavigator: useRootNavigator,
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
      centered: centered,
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
