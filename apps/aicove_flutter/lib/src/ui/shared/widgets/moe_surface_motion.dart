import 'package:flutter/material.dart';

/// Marks content inside a scroll view whose scrolling is only an overflow
/// fallback (for example a fixed action grid under a very large text scale).
///
/// Surfaces below this marker ignore the nearest enclosing [Scrollable] when
/// deciding whether they move, so they keep the global material. Drag sheets,
/// slider followers and reorder proxies above it still force a solid fill.
/// Do not use it for lists or content that is expected to scroll.
class MoeRarelyScrolledRegion extends StatelessWidget {
  const MoeRarelyScrolledRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Whether this surface itself can move with scrolling or a drag gesture.
/// A scrollable below the surface does not move its surrounding material.
bool moeSurfaceMovesWithContent(BuildContext context) {
  var moves = false;
  var nearestScrollResolved = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (!nearestScrollResolved) {
      if (widget is MoeRarelyScrolledRegion) {
        nearestScrollResolved = true;
      } else if (widget is Scrollable) {
        moves = true;
        return false;
      }
    }
    moves =
        (widget is BottomSheet &&
            (widget.enableDrag ||
                (widget.showDragHandle ??
                    Theme.of(context).bottomSheetTheme.showDragHandle ??
                    false))) ||
        widget is DraggableScrollableSheet ||
        // Slider thumbs move in the compositor without relaying out the glass.
        widget is CompositedTransformFollower ||
        // The drag proxy keeps this listener after leaving the scroll viewport.
        widget is ReorderableDragStartListener;
    return !moves;
  });
  return moves;
}
