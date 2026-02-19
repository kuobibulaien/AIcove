/// MoeActionSheet - iOS 风格底部操作菜单
/// 
/// 用于显示一组操作选项，类似 iOS 的 ActionSheet。
/// 
/// 设计特点：
/// - 底部弹出，带圆角
/// - 顶部拖动指示器
/// - 可选的标题和描述
/// - 操作项列表（支持图标、文字、危险操作）
/// - 底部取消按钮（可选）
/// - iOS 风格无水波纹交互
/// 
/// 使用示例：
/// ```dart
/// await showMoeActionSheet(
///   context: context,
///   title: '渠道操作',
///   actions: [
///     MoeSheetAction(icon: Icons.edit, label: '编辑', onTap: () {}),
///     MoeSheetAction(icon: Icons.delete, label: '删除', isDestructive: true, onTap: () {}),
///   ],
/// );
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建底部操作菜单组件
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 操作项定义
class MoeSheetAction {
  const MoeSheetAction({
    required this.label,
    required this.onTap,
    this.icon,
    this.isDestructive = false,
    this.isDisabled = false,
    this.subtitle,
  });

  /// 操作标签
  final String label;

  /// 点击回调
  final VoidCallback onTap;

  /// 可选图标
  final IconData? icon;

  /// 是否为危险操作（显示红色）
  final bool isDestructive;

  /// 是否禁用
  final bool isDisabled;

  /// 副标题（可选）
  final String? subtitle;
}

/// 显示底部操作菜单
Future<void> showMoeActionSheet({
  required BuildContext context,
  String? title,
  String? description,
  required List<MoeSheetAction> actions,
  bool showCancelButton = true,
  String cancelText = '取消',
  bool enableHaptics = true,
}) async {
  if (enableHaptics) {
    HapticFeedback.lightImpact();
  }

  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => MoeActionSheet(
      title: title,
      description: description,
      actions: actions,
      showCancelButton: showCancelButton,
      cancelText: cancelText,
      enableHaptics: enableHaptics,
    ),
  );
}

/// 底部操作菜单组件
class MoeActionSheet extends StatelessWidget {
  const MoeActionSheet({
    super.key,
    this.title,
    this.description,
    required this.actions,
    this.showCancelButton = true,
    this.cancelText = '取消',
    this.enableHaptics = true,
  });

  final String? title;
  final String? description;
  final List<MoeSheetAction> actions;
  final bool showCancelButton;
  final String cancelText;
  final bool enableHaptics;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBgColor = isDark ? colors.surface : Colors.white;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 主体卡片
            MoeG2ClipRRect(
              radius: 14,
              child: Container(
                color: sheetBgColor,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 顶部拖动指示器
                    Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 4),
                      width: 36,
                      height: 4,
                      decoration: MoeG2Decoration(
                        radius: 2,
                        color: colors.muted.withValues(alpha: 0.3),
                      ),
                    ),

                  // 标题区域
                  if (title != null || description != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: Column(
                        children: [
                          if (title != null)
                            Text(
                              title!,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: MoeFontWeights.emphasis,
                                color: colors.muted,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          if (description != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              description!,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.muted.withValues(alpha: 0.8),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),

                  // 分隔线
                  if (title != null || description != null)
                    Divider(height: 1, color: colors.borderLight),

                  // 操作项列表
                  ...actions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final action = entry.value;
                    final isLast = index == actions.length - 1;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionItem(
                          action: action,
                          enableHaptics: enableHaptics,
                          onTap: () {
                            Navigator.pop(context);
                            action.onTap();
                          },
                        ),
                        if (!isLast)
                          Divider(
                            height: 1,
                            color: colors.borderLight,
                            indent: action.icon != null ? 52 : 16,
                          ),
                      ],
                    );
                  }),
                  ],
                ),
              ),
            ),

            // 取消按钮
            if (showCancelButton) ...[
              const SizedBox(height: 8),
              MoeG2ClipRRect(
                radius: 14,
                child: Container(
                  width: double.infinity,
                  color: sheetBgColor,
                  child: _ActionItem(
                    action: MoeSheetAction(
                      label: cancelText,
                      onTap: () {},
                    ),
                    enableHaptics: enableHaptics,
                    isCancelButton: true,
                    onTap: () => Navigator.pop(context),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单个操作项
class _ActionItem extends StatefulWidget {
  const _ActionItem({
    required this.action,
    required this.onTap,
    this.enableHaptics = true,
    this.isCancelButton = false,
  });

  final MoeSheetAction action;
  final VoidCallback onTap;
  final bool enableHaptics;
  final bool isCancelButton;

  @override
  State<_ActionItem> createState() => _ActionItemState();
}

class _ActionItemState extends State<_ActionItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final action = widget.action;
    final isEnabled = !action.isDisabled;

    // 颜色计算
    Color textColor;
    if (action.isDisabled) {
      textColor = colors.muted.withValues(alpha: 0.5);
    } else if (action.isDestructive) {
      textColor = Colors.red;
    } else if (widget.isCancelButton) {
      textColor = colors.primary;
    } else {
      textColor = colors.text;
    }

    final bgColor = _pressed && isEnabled
        ? colors.surfaceAlt.withValues(alpha: 0.5)
        : Colors.transparent;

    return GestureDetector(
      onTapDown: isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: isEnabled
          ? () {
              if (widget.enableHaptics) {
                HapticFeedback.selectionClick();
              }
              widget.onTap();
            }
          : null,
      child: AnimatedContainer(
        duration: kAnimFast,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        color: bgColor,
        child: Row(
          children: [
            // 图标
            if (action.icon != null) ...[
              SizedBox(
                width: 36,
                child: Icon(
                  action.icon,
                  size: 22,
                  color: textColor,
                ),
              ),
              const SizedBox(width: 12),
            ],

            // 文字区域
            Expanded(
              child: Column(
                crossAxisAlignment: action.icon != null
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    action.label,
                    style: TextStyle(
                      fontSize: widget.isCancelButton ? 17 : 16,
                      fontWeight: widget.isCancelButton
                          ? MoeFontWeights.emphasis
                          : MoeFontWeights.emphasis,
                      color: textColor,
                    ),
                  ),
                  if (action.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      action.subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
