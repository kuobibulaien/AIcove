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

import '../../animations/moe_menu_transition.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../moe_floating_surface.dart';
import '../../../theme/tokens.dart';
import '../../effects/smooth_clip.dart';

/// 菜单项数据
class MoePopupMenuItem {
  final Key? key;
  final bool? checked;
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final double width;

  const MoePopupMenuItem({
    this.key,
    this.checked,
    this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.width = 56,
  });
}

/// 悬浮气泡菜单
class MoePopupMenu {
  /// 显示悬浮菜单
  ///
  /// [targetBox] 目标元素的 RenderBox，菜单会显示在其上方或下方
  /// [globalPosition] 实际点击或长按位置；未提供时锚定目标控件边缘。
  /// [items] 菜单项列表
  static Future<void> show(
    BuildContext context, {
    required RenderBox targetBox,
    Offset? globalPosition,
    required List<MoePopupMenuItem> items,
    bool vertical = true,
    bool alignToEnd = false,
  }) async {
    if (items.isEmpty || !targetBox.attached) return;
    if (vertical) {
      final navigator = Navigator.of(context);
      final overlayBox = navigator.overlay?.context.findRenderObject();
      if (overlayBox is! RenderBox) return;
      final target = targetBox.localToGlobal(Offset.zero, ancestor: overlayBox);
      final route = RawDialogRoute<MoePopupMenuItem>(
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: Colors.transparent,
        transitionDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : MoeMenuTransition.duration,
        pageBuilder: (context, animation, secondaryAnimation) => _VerticalMenu(
          animation: animation,
          items: items,
          anchor: globalPosition == null
              ? Rect.fromLTWH(
                  target.dx,
                  target.dy,
                  targetBox.size.width,
                  targetBox.size.height,
                )
              : Rect.fromLTWH(
                  overlayBox.globalToLocal(globalPosition).dx,
                  overlayBox.globalToLocal(globalPosition).dy,
                  0,
                  0,
                ),
          alignToEnd: alignToEnd,
        ),
        transitionBuilder: (context, animation, secondaryAnimation, child) =>
            child,
      );
      final selected = await navigator.push(route);
      await route.completed;
      if (context.mounted) selected?.onTap();
      return;
    }
    final box = targetBox;

    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    // 计算目标元素在 overlay 中的位置
    final targetTopLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final targetSize = box.size;
    final screenSize = overlayBox.size;
    final insets = MediaQuery.of(context).padding;

    // 菜单尺寸估算
    const double menuHeight = 52.0;
    const double arrowHeight = 8.0;
    final double menuWidth =
        items.fold<double>(0, (sum, item) => sum + item.width) +
        (items.length - 1) * 0.5;

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
    final availableAbove =
        targetTopLeft.dy - verticalGap - arrowHeight - insets.top - 12;
    final availableBelow =
        screenSize.height -
        insets.bottom -
        (targetTopLeft.dy + targetSize.height + verticalGap + arrowHeight) -
        12;

    final bool placeAbove =
        availableAbove >= menuHeight || availableAbove > availableBelow;
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: MoeMenuTransition.duration,
      vsync: this,
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
                child: MoeMenuTransition(
                  animation: _controller,
                  alignment: Alignment(
                    (widget.arrowOffsetX / widget.menuWidth * 2 - 1).clamp(
                      -1.0,
                      1.0,
                    ),
                    widget.placeAbove ? 1 : -1,
                  ),
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
    final bgColor = MoeGlassTheme.maybeOf(context)?.enabled == false
        ? colors.surface
        : colors.glassSurface;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上方箭头（当菜单在下方时）
        if (!placeAbove) _buildArrow(bgColor, pointUp: true),
        // 菜单主体
        MoeFloatingSurface(
          baseline: MoeMaterialBaseline.text,
          radius: 10,
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
                      Container(width: 0.5, height: 28, color: colors.divider),
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

  Widget _buildMenuItem(
    BuildContext context,
    MoePopupMenuItem item,
    MoeColors colors,
    bool isDark,
  ) {
    final fg = item.danger ? Colors.red : (isDark ? Colors.white : colors.text);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          onItemTap?.call();
          item.onTap();
        },
        child: Container(
          width: item.width,
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      color: fg,
                      fontWeight: MoeFontWeights.emphasis,
                    ),
                  ),
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

/// A local, keyboard-accessible menu with one material for the entire scroll area.
class _VerticalMenu extends StatelessWidget {
  const _VerticalMenu({
    required this.animation,
    required this.items,
    required this.anchor,
    required this.alignToEnd,
  });
  final Animation<double> animation;
  final List<MoePopupMenuItem> items;
  final Rect anchor;
  final bool alignToEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return MoeMenuTransition(
      animation: animation,
      origin: alignToEnd ? anchor.bottomRight : anchor.bottomLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final media = MediaQuery.of(context);
          final bounds = Rect.fromLTRB(
            media.padding.left + 8,
            media.padding.top + 8,
            math.max(
              media.padding.left + 8,
              constraints.maxWidth - media.padding.right - 8,
            ),
            math.max(
              media.padding.top + 8,
              constraints.maxHeight -
                  math.max(media.padding.bottom, media.viewInsets.bottom) -
                  8,
            ),
          );
          final width = math.min(bounds.width, 180.0);
          final x = (alignToEnd ? anchor.right - width : anchor.left).clamp(
            bounds.left,
            bounds.right - width,
          );
          final anchorY = anchor.top.clamp(bounds.top, bounds.bottom);
          final below = anchor.bottom.clamp(bounds.top, bounds.bottom);
          final maxHeight = math.max(
            anchorY - bounds.top,
            bounds.bottom - below,
          );
          return Stack(
            children: [
              CustomSingleChildLayout(
                delegate: _MenuPosition(
                  x: x,
                  anchor: anchor,
                  maxHeight: maxHeight,
                  bounds: bounds,
                ),
                child: SizedBox(
                  width: width,
                  child: MoeFloatingSurface(
                    baseline: MoeMaterialBaseline.text,
                    radius: 14,
                    child: Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.arrowDown):
                            NextFocusIntent(),
                        SingleActivator(LogicalKeyboardKey.arrowUp):
                            PreviousFocusIntent(),
                        SingleActivator(LogicalKeyboardKey.escape):
                            DismissIntent(),
                      },
                      child: Actions(
                        actions: {
                          DismissIntent: CallbackAction<DismissIntent>(
                            onInvoke: (_) {
                              Navigator.of(context).pop();
                              return null;
                            },
                          ),
                        },
                        child: FocusTraversalGroup(
                          child: Focus(
                            autofocus: true,
                            skipTraversal: true,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var index = 0;
                                    index < items.length;
                                    index++
                                  )
                                    Semantics(
                                      checked: items[index].checked,
                                      child: TextButton(
                                        key: items[index].key,
                                        style: TextButton.styleFrom(
                                          overlayColor: Colors.transparent,
                                          alignment: Alignment.centerLeft,
                                          foregroundColor: items[index].danger
                                              ? Colors.red
                                              : colors.text,
                                          minimumSize: const Size(
                                            double.infinity,
                                            36,
                                          ),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                        onPressed: () => Navigator.of(
                                          context,
                                        ).pop(items[index]),
                                        child: Row(
                                          children: [
                                            if (items[index].checked !=
                                                null) ...[
                                              SizedBox(
                                                width: 18,
                                                child: items[index].checked!
                                                    ? const Icon(
                                                        Icons.check,
                                                        size: 18,
                                                      )
                                                    : null,
                                              ),
                                              const SizedBox(width: 6),
                                            ],
                                            Expanded(
                                              child: Text(
                                                items[index].label,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MenuPosition extends SingleChildLayoutDelegate {
  const _MenuPosition({
    required this.x,
    required this.anchor,
    required this.maxHeight,
    required this.bounds,
  });
  final Rect bounds;
  final double x;
  final Rect anchor;
  final double maxHeight;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen().copyWith(maxHeight: maxHeight);
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final below = anchor.bottom.clamp(bounds.top, bounds.bottom);
    final preferred = below + childSize.height <= bounds.bottom
        ? below
        : anchor.top.clamp(bounds.top, bounds.bottom) - childSize.height;
    return Offset(
      x,
      preferred.clamp(
        bounds.top,
        math.max(bounds.top, bounds.bottom - childSize.height),
      ),
    );
  }

  @override
  bool shouldRelayout(_MenuPosition oldDelegate) =>
      x != oldDelegate.x ||
      anchor != oldDelegate.anchor ||
      maxHeight != oldDelegate.maxHeight ||
      bounds != oldDelegate.bounds;
}
