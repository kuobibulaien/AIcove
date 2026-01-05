/// MoeBottomSheet - 通用底部弹窗容器
/// 
/// 用于自定义内容的底部弹窗，提供统一的样式和行为。
/// 
/// 设计特点：
/// - 底部弹出，带圆角
/// - 顶部拖动指示器
/// - 可选的标题栏
/// - 自动处理 SafeArea
/// - 支持自定义高度
/// 
/// 使用示例：
/// ```dart
/// await showMoeBottomSheet(
///   context: context,
///   title: '选择模型',
///   builder: (context) => ListView.builder(...),
/// );
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建通用底部弹窗组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 显示底部弹窗
Future<T?> showMoeBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  String? title,
  Widget? titleTrailing,
  bool showDragHandle = true,
  bool showCloseButton = false,
  double? maxHeight,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) async {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    builder: (context) => MoeBottomSheet(
      title: title,
      titleTrailing: titleTrailing,
      showDragHandle: showDragHandle,
      showCloseButton: showCloseButton,
      maxHeight: maxHeight,
      child: builder(context),
    ),
  );
}

/// 底部弹窗容器组件
class MoeBottomSheet extends StatelessWidget {
  const MoeBottomSheet({
    super.key,
    required this.child,
    this.title,
    this.titleTrailing,
    this.showDragHandle = true,
    this.showCloseButton = false,
    this.maxHeight,
  });

  final Widget child;
  final String? title;
  final Widget? titleTrailing;
  final bool showDragHandle;
  final bool showCloseButton;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;
    final screenHeight = MediaQuery.of(context).size.height;
    final effectiveMaxHeight = maxHeight ?? screenHeight * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
      decoration: BoxDecoration(
        color: sheetBgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部拖动指示器
            if (showDragHandle)
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.muted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

            // 标题栏
            if (title != null || showCloseButton || titleTrailing != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    // 左侧关闭按钮占位
                    if (showCloseButton)
                      IconButton(
                        icon: const Icon(Icons.close),
                        iconSize: 20,
                        color: colors.muted,
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                      )
                    else
                      const SizedBox(width: 32),

                    // 标题居中
                    Expanded(
                      child: title != null
                          ? Text(
                              title!,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: colors.text,
                              ),
                              textAlign: TextAlign.center,
                            )
                          : const SizedBox.shrink(),
                    ),

                    // 右侧控件
                    titleTrailing ?? const SizedBox(width: 32),
                  ],
                ),
              ),

            // 分隔线
            if (title != null || showCloseButton || titleTrailing != null)
              Divider(height: 1, color: colors.borderLight),

            // 内容区域
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}
