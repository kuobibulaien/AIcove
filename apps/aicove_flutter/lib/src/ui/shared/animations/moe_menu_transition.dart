import 'package:flutter/material.dart';

/// Shared anchored entrance and exit for popup menus.
///
/// [origin] is in the child's coordinate space. Full-overlay menus pass their
/// local pointer position; content-sized menus can use [alignment] instead.
class MoeMenuTransition extends StatelessWidget {
  const MoeMenuTransition({
    super.key,
    required this.animation,
    required this.child,
    this.origin,
    this.alignment = Alignment.topLeft,
  });

  static const duration = Duration(milliseconds: 240);
  final Animation<double> animation;
  final Widget child;
  final Offset? origin;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        // One curve for both directions keeps interrupted transitions continuous.
        final progress = Curves.easeOutCubic.transform(animation.value);
        // Keep live glass on the page compositor. An outer Opacity creates an
        // offscreen buffer that produces displaced black shader regions on Android.
        // Grow from a small footprint at the trigger, like an iOS context menu.
        return Transform.scale(
          scale: 0.08 + 0.92 * progress,
          origin: origin,
          alignment: origin == null ? alignment : Alignment.topLeft,
          child: child,
        );
      },
    );
  }
}
