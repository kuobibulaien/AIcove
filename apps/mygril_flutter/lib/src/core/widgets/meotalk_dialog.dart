import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// MeoTalk 风格确认弹窗
/// 
/// 特点：
/// - 标题下方带黄色装饰线
/// - 右上角有关闭按钮（X图标）
/// - 黄色确认按钮 + 蓝灰色取消按钮
/// - Material Design 阴影效果
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
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 8,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500, minWidth: 400),
        padding: const EdgeInsets.all(40), // 增大内边距
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题区域 - 居中布局
            Stack(
              children: [
                // 标题 + 装饰线居中
                Center(
                  child: Column(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 32, // 加大字号
                          fontWeight: FontWeight.w700, // 加粗
                          color: moeText,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      // 黄色装饰线 - 居中且加长
                      Container(
                        height: 4, // 加粗
                        width: 200, // 加长
                        decoration: BoxDecoration(
                          color: moeDialogAccentLine,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
                // 关闭按钮 - 右上角
                if (barrierDismissible)
                  Positioned(
                    top: -8,
                    right: -8,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 32), // 增大图标
                      onPressed: () => Navigator.of(context).pop(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      style: IconButton.styleFrom(
                        foregroundColor: Colors.black, // 改为黑色
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 40), // 增大间距
            
            // 内容区域
            DefaultTextStyle(
              style: const TextStyle(
                fontSize: 18,
                color: moeText,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
              child: content,
            ),
            
            const SizedBox(height: 40), // 增大间距
            
            // 按钮区域 - 居中
            Row(
              mainAxisAlignment: MainAxisAlignment.center, // 居中
              children: [
                // 取消按钮
                if (showCancelButton)
                  _buildCancelButton(context),
                if (showCancelButton && showConfirmButton)
                  const SizedBox(width: 24), // 增大按钮间距
                // 确认按钮
                if (showConfirmButton)
                  _buildConfirmButton(context),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCancelButton(BuildContext context) {
    return SizedBox(
      width: 180, // 固定宽度
      height: 56, // 固定高度
      child: TextButton(
        onPressed: onCancel ?? () => Navigator.of(context).pop(),
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFFDAE5F1), // 浅蓝灰色背景
          foregroundColor: moeText, // 深色文字
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8), // 加大圆角
          ),
        ),
        child: Text(
          cancelText ?? '取消',
          style: const TextStyle(
            fontSize: 20, // 加大字号
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmButton(BuildContext context) {
    return SizedBox(
      width: 180, // 固定宽度
      height: 56, // 固定高度
      child: ElevatedButton(
        onPressed: onConfirm,
        style: ElevatedButton.styleFrom(
          backgroundColor: moeDialogWarning, // 黄色背景
          foregroundColor: moeText, // 深色文字（不是白色！）
          elevation: 2,
          shadowColor: Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8), // 加大圆角
          ),
        ),
        child: Text(
          confirmText ?? '确认',
          style: const TextStyle(
            fontSize: 20, // 加大字号
            fontWeight: FontWeight.w700, // 加粗
          ),
        ),
      ),
    );
  }
}

/// 显示 MeoTalk 风格确认弹窗的便捷函数
Future<bool?> showMeoTalkDialog({
  required BuildContext context,
  required String title,
  required Widget content,
  String? cancelText,
  String? confirmText,
  bool showCancelButton = true,
  bool showConfirmButton = true,
  bool barrierDismissible = true,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => MeoTalkDialog(
      title: title,
      content: content,
      cancelText: cancelText,
      confirmText: confirmText,
      showCancelButton: showCancelButton,
      showConfirmButton: showConfirmButton,
      barrierDismissible: barrierDismissible,
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
}) {
  return showMeoTalkDialog(
    context: context,
    title: title,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center, // 改为居中
      children: [
        Text(
          message,
          style: const TextStyle(
            fontSize: 20, // 加大字号
            color: moeText,
            height: 1.6,
          ),
          textAlign: TextAlign.center, // 文字居中
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            style: const TextStyle(
              fontSize: 16, // 稍微加大
              color: moeTextSecondary,
              height: 1.5,
            ),
            textAlign: TextAlign.center, // 文字居中
          ),
        ],
      ],
    ),
    cancelText: cancelText,
    confirmText: confirmText,
  );
}
