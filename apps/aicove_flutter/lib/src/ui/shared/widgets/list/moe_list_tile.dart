/// MoeListTile - 通用列表项组件
/// 
/// 用于聊天列表、联系人列表等业务场景。
/// 
/// 设计特点：
/// - 灵活的布局（leading + title + subtitle + trailing）
/// - iOS 风格交互
/// - 支持选中状态
/// - 完整的样式接口
/// 
/// 使用示例：
/// ```dart
/// MoeListTile(
///   leading: CircleAvatar(child: Text('A')),
///   title: '联系人名称',
///   subtitle: '最后一条消息...',
///   trailing: Text('12:30'),
///   onTap: () => openChat(),
/// )
/// ```
/// 
/// 更新记录：
/// - 2025-12-31: 创建通用列表项组件
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';

/// 通用列表项组件
class MoeListTile extends StatefulWidget {
  const MoeListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.enabled = true,
    // === 样式接口 ===
    this.backgroundColor,
    this.selectedBackgroundColor,
    this.pressedBackgroundColor,
    this.titleStyle,
    this.subtitleStyle,
    this.contentPadding,
    this.minLeadingWidth,
    this.horizontalGap,
    this.minVerticalPadding,
  });

  /// 左侧控件（如头像）
  final Widget? leading;

  /// 标题
  final Widget title;

  /// 副标题
  final Widget? subtitle;

  /// 右侧控件
  final Widget? trailing;

  /// 点击回调
  final VoidCallback? onTap;

  /// 长按回调
  final VoidCallback? onLongPress;

  /// 是否选中
  final bool selected;

  /// 是否启用
  final bool enabled;

  // === 样式接口 ===
  
  final Color? backgroundColor;
  final Color? selectedBackgroundColor;
  final Color? pressedBackgroundColor;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final EdgeInsets? contentPadding;
  final double? minLeadingWidth;
  final double? horizontalGap;
  final double? minVerticalPadding;

  @override
  State<MoeListTile> createState() => _MoeListTileState();
}

class _MoeListTileState extends State<MoeListTile> {
  bool _pressed = false;

  bool get _isEnabled => widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    
    // 解析样式
    final bgColor = widget.backgroundColor ?? Colors.transparent;
    final selectedBg = widget.selectedBackgroundColor ?? colors.focus.withValues(alpha: 0.1);
    final pressedBg = widget.pressedBackgroundColor ?? colors.surfaceAlt.withValues(alpha: 0.5);
    final padding = widget.contentPadding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    final leadingWidth = widget.minLeadingWidth ?? 48;
    final gap = widget.horizontalGap ?? 12;

    // 计算当前背景色
    Color currentBg;
    if (_pressed && _isEnabled) {
      currentBg = pressedBg;
    } else if (widget.selected) {
      currentBg = selectedBg;
    } else {
      currentBg = bgColor;
    }

    return GestureDetector(
      onTapDown: _isEnabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _isEnabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _isEnabled ? () => setState(() => _pressed = false) : null,
      onTap: _isEnabled ? widget.onTap : null,
      onLongPress: _isEnabled ? widget.onLongPress : null,
      onSecondaryTapUp: (_isEnabled && widget.onLongPress != null)
          ? (_) => widget.onLongPress!()
          : null,
      child: AnimatedContainer(
        duration: kAnimFast,
        color: currentBg,
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Leading
            if (widget.leading != null) ...[
              ConstrainedBox(
                constraints: BoxConstraints(minWidth: leadingWidth),
                child: widget.leading,
              ),
              SizedBox(width: gap),
            ],
            
            // Title + Subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  DefaultTextStyle(
                    style: widget.titleStyle ?? TextStyle(
                      fontSize: 15,
                      fontWeight: MoeFontWeights.emphasis,
                      color: widget.enabled ? colors.text : colors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: widget.title,
                  ),
                  if (widget.subtitle != null) ...[
                    const SizedBox(height: 2),
                    DefaultTextStyle(
                      style: widget.subtitleStyle ?? TextStyle(
                        fontSize: 13,
                        color: widget.enabled ? colors.muted : colors.muted.withValues(alpha: 0.6),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: widget.subtitle!,
                    ),
                  ],
                ],
              ),
            ),
            
            // Trailing
            if (widget.trailing != null) ...[
              SizedBox(width: gap),
              widget.trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
