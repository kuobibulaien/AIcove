import 'package:flutter/material.dart';

/// Whether this surface itself can move with scrolling or a drag gesture.
/// A scrollable below the surface does not move its surrounding material.
bool moeSurfaceMovesWithContent(BuildContext context) {
  if (Scrollable.maybeOf(context) != null) return true;

  var moves = false;
  context.visitAncestorElements((element) {
    final widget = element.widget;
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
