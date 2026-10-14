import 'package:flutter/material.dart';

import 'moe_scroll_behavior.dart';

/// Marks content inside a scroll view whose scrolling is only an overflow
/// fallback (for example a fixed action grid under a very large text scale).
///
/// Surfaces below this marker ignore the nearest enclosing [Scrollable] when
/// deciding whether they move, so they keep the global material. Reorder
/// proxies above it still force a solid fill.
/// Do not use it for lists or content that is expected to scroll.
class MoeRarelyScrolledRegion extends StatelessWidget {
  const MoeRarelyScrolledRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Whether this surface itself can move with scrolling or a drag gesture.
/// A scrollable below the surface does not move its surrounding material.
///
/// [ignoreScrollables] skips the scroll check for materials that stay correct
/// while scrolling. Backdrop blur only failed under Android's stretch
/// overscroll, which [MoeScrollBehavior] replaces with bouncing; liquid
/// surfaces in a scroll view switch to `GlassQuality.standard`.
bool moeSurfaceMovesWithContent(
  BuildContext context, {
  bool ignoreScrollables = false,
}) {
  var moves = false;
  var nearestScrollResolved = ignoreScrollables;
  var inReorderListener = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (inReorderListener) {
      if (widget is Scrollable) {
        inReorderListener = false;
        return false;
      }
      if (widget is Overlay) {
        moves = true;
        return false;
      }
      return true;
    }
    if (!nearestScrollResolved) {
      if (widget is MoeRarelyScrolledRegion) {
        nearestScrollResolved = true;
      } else if (widget is Scrollable) {
        moves = true;
        return false;
      }
    }
    if (!ignoreScrollables) {
      moves =
          (widget is BottomSheet &&
              (widget.enableDrag ||
                  (widget.showDragHandle ??
                      Theme.of(context).bottomSheetTheme.showDragHandle ??
                      false))) ||
          widget is DraggableScrollableSheet ||
          // Slider thumbs move in the compositor; use the motion-safe shader.
          widget is CompositedTransformFollower;
      if (moves) return false;
    }
    // The drag proxy keeps this listener after leaving the scroll viewport.
    if (widget is ReorderableDragStartListener) {
      if (!ignoreScrollables) {
        moves = true;
        return false;
      }
      inReorderListener = true;
    }
    return !moves;
  });
  return moves || inReorderListener;
}
