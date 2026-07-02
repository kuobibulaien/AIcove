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
import 'package:figma_squircle/figma_squircle.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 显示底部弹窗
///
/// 动画时长：150ms（比默认 250ms 快），匹配系统键盘速度
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
  bool useRootNavigator = false,
}) async {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    // 注意：transitionAnimationController 需要 StatefulWidget 的 TickerProvider
    // 这里使用 showGeneralDialog 替代方案或接受默认动画
    // 由于 AnimatedPadding 已使用 kAnimXFast，整体体验已足够流畅
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
///
/// **键盘处理规范**：
/// - 不再把“整个 sheet”往上顶（用户观感像整块界面飞起来）
/// - 改为：sheet 外框位置不动，内部内容区域用 `AnimatedPadding(bottom: viewInsets.bottom)` 给键盘让位
/// - builder 内部仍然使用**固定 padding**，不要使用动态 viewInsets
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
    final screenHeight = MediaQuery.sizeOf(context).height;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final effectiveMaxHeight = maxHeight ?? screenHeight * 0.85;

    const sheetBorderRadius = SmoothBorderRadius.vertical(
      top: SmoothRadius(cornerRadius: 16, cornerSmoothing: 0.6),
    );

    // 关键：不把整个 sheet 往上顶（会出现“整块界面上移”的观感）。
    // 只在内部内容区留出键盘高度，这样看起来像“输入区抬起”，外框不动。
    return Container(
      constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
      decoration: ShapeDecoration(
        color: sheetBgColor,
        shape: SmoothRectangleBorder(
          borderRadius: sheetBorderRadius,
          side: BorderSide(
            color: colors.border.withValues(alpha: isDark ? 0.3 : 0.15),
            width: 0.5,
          ),
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 16,
            spreadRadius: 0,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: MoeG2ClipRRect.borderRadius(
        borderRadius: sheetBorderRadius,
        child: SafeArea(
          child: AnimatedPadding(
            duration: kAnimFast,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部拖动指示器
                if (showDragHandle)
                  Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: MoeG2Decoration(
                      radius: 2,
                      color: colors.muted.withValues(alpha: 0.3),
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
                                    fontWeight: MoeFontWeights.emphasis,
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
        ),
      ),
    );
  }
}
