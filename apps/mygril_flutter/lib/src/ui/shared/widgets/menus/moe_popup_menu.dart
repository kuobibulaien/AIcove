/// 悬浮气泡菜单组件
/// 
/// 类似 QQ/微信 长按消息出现的气泡菜单，显示在目标元素上方，带小尖尖指向消息。
/// 
/// 使用方式：
/// ```dart
/// MoePopupMenu.show(
///   context,
///   targetKey: _bubbleKey,  // 目标元素的 GlobalKey
///   items: [
///     MoePopupMenuItem(icon: Icons.copy, label: '复制', onTap: () {}),
///     MoePopupMenuItem(icon: Icons.edit, label: '编辑', onTap: () {}),
///   ],
/// );
/// ```
library;

import 'package:flutter/material.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 菜单项数据
class MoePopupMenuItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const MoePopupMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

/// 悬浮气泡菜单
class MoePopupMenu {
  /// 显示悬浮菜单
  /// 
  /// [targetKey] 目标元素的 GlobalKey，菜单会显示在其上方或下方
  /// [items] 菜单项列表
  static Future<void> show(
    BuildContext context, {
    required GlobalKey targetKey,
    required List<MoePopupMenuItem> items,
  }) async {
    final box = targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    // 计算目标元素在 overlay 中的位置
    final targetTopLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final targetSize = box.size;
    final screenSize = overlayBox.size;
    final insets = MediaQuery.of(context).padding;

    // 菜单尺寸估算
    const double itemWidth = 56.0;
    const double menuHeight = 52.0;
    const double arrowHeight = 8.0;
    final double menuWidth = items.length * itemWidth;

    // 计算目标元素中心点
    final targetCenterX = targetTopLeft.dx + targetSize.width / 2;

    // 水平位置：居中对齐目标元素
    double x = targetCenterX - menuWidth / 2;
    // 边界约束
    final minX = insets.left + 8.0;
    final maxX = screenSize.width - insets.right - menuWidth - 8.0;
    x = x.clamp(minX, maxX);

    // 计算箭头相对于菜单的水平偏移
    final arrowOffsetX = targetCenterX - x;

    // 垂直位置：优先显示在上方，增加间距
    const double verticalGap = 6.0; // 菜单与气泡的间距
    final availableAbove = targetTopLeft.dy - verticalGap - arrowHeight - insets.top - 12;
    final availableBelow = screenSize.height - insets.bottom - (targetTopLeft.dy + targetSize.height + verticalGap + arrowHeight) - 12;
    
    final bool placeAbove = availableAbove >= menuHeight || availableAbove > availableBelow;
    final double y = placeAbove
        ? targetTopLeft.dy - menuHeight - arrowHeight - verticalGap
        : targetTopLeft.dy + targetSize.height + verticalGap;

    // 使用 Overlay 代替 showGeneralDialog，避免输入法收回
    final overlayState = Overlay.of(context);
    late OverlayEntry entry;
    
    entry = OverlayEntry(
      builder: (ctx) => _PopupMenuOverlay(
        x: x,
        y: y,
        items: items,
        placeAbove: placeAbove,
        arrowOffsetX: arrowOffsetX,
        menuWidth: menuWidth,
        onDismiss: () => entry.remove(),
      ),
    );

    overlayState.insert(entry);
  }
}

/// Overlay 包装器，处理点击外部关闭
class _PopupMenuOverlay extends StatefulWidget {
  final double x;
  final double y;
  final List<MoePopupMenuItem> items;
  final bool placeAbove;
  final double arrowOffsetX;
  final double menuWidth;
  final VoidCallback onDismiss;

  const _PopupMenuOverlay({
    required this.x,
    required this.y,
    required this.items,
    required this.placeAbove,
    required this.arrowOffsetX,
    required this.menuWidth,
    required this.onDismiss,
  });

  @override
  State<_PopupMenuOverlay> createState() => _PopupMenuOverlayState();
}

class _PopupMenuOverlayState extends State<_PopupMenuOverlay> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismiss,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned(
              left: widget.x,
              top: widget.y,
              child: GestureDetector(
                onTap: () {}, // 阻止点击穿透
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    alignment: widget.placeAbove 
                        ? Alignment.bottomCenter 
                        : Alignment.topCenter,
                    child: _PopupMenuContent(
                      items: widget.items,
                      placeAbove: widget.placeAbove,
                      arrowOffsetX: widget.arrowOffsetX,
                      menuWidth: widget.menuWidth,
                      onItemTap: _dismiss,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PopupMenuContent extends StatelessWidget {
  final List<MoePopupMenuItem> items;
  final bool placeAbove;
  final double arrowOffsetX;
  final double menuWidth;
  final VoidCallback? onItemTap;

  const _PopupMenuContent({
    required this.items, 
    required this.placeAbove,
    required this.arrowOffsetX,
    required this.menuWidth,
    this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF3A3A3C) : Colors.white;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上方箭头（当菜单在下方时）
        if (!placeAbove) _buildArrow(bgColor, pointUp: true),
        // 菜单主体
        Container(
          decoration: MoeG2Decoration(
            radius: 10,
            color: bgColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: MoeG2ClipRRect(
            radius: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: items.asMap().entries.map((entry) {
                final index = entry.key;
                final item = entry.value;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMenuItem(context, item, colors, isDark),
                    if (index < items.length - 1)
                      Container(
                        width: 0.5,
                        height: 28,
                        color: colors.divider,
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
        // 下方箭头（当菜单在上方时）
        if (placeAbove) _buildArrow(bgColor, pointUp: false),
      ],
    );
  }

  Widget _buildArrow(Color bgColor, {required bool pointUp}) {
    // 箭头位置约束
    final clampedOffset = arrowOffsetX.clamp(16.0, menuWidth - 16.0);
    
    return SizedBox(
      width: menuWidth,
      height: 8,
      child: Stack(
        children: [
          Positioned(
            left: clampedOffset - 8,
            child: CustomPaint(
              size: const Size(16, 8),
              painter: _ArrowPainter(color: bgColor, pointUp: pointUp),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(BuildContext context, MoePopupMenuItem item, MoeColors colors, bool isDark) {
    final fg = item.danger ? Colors.red : (isDark ? Colors.white : colors.text);
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          onItemTap?.call();
          item.onTap();
        },
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 20, color: fg),
              const SizedBox(height: 2),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 11,
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 绘制三角形箭头
class _ArrowPainter extends CustomPainter {
  final Color color;
  final bool pointUp;

  _ArrowPainter({required this.color, required this.pointUp});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();
    if (pointUp) {
      // 向上的箭头
      path.moveTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    } else {
      // 向下的箭头
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
