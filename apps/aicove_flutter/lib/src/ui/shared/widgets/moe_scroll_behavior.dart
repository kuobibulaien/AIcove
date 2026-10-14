import 'package:flutter/material.dart';

/// App-wide scrolling: iOS-style bounce on every platform.
///
/// Android's stretch overscroll paints the whole scroll view through an
/// ImageFilter layer while stretching. Every BackdropFilter inside it then
/// samples that empty layer instead of the wallpaper, so frosted surfaces
/// drop to their bare tint. Bouncing only translates the content.
class MoeScrollBehavior extends MaterialScrollBehavior {
  const MoeScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
