import 'package:flutter/material.dart';

import '../effects/smooth_clip.dart';

/// Fill of [MoeInsetSurface]: Apple's tertiarySystemFill (#767680 at 12%
/// light, 24% dark).
Color moeInsetFill(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0x3D767680)
    : const Color(0x1F767680);

/// Emphasis block nested inside a card or frame: badges, text wells, image
/// slots and their placeholders. The fill is a translucent system fill, so it
/// reads the same on solid, frosted and glass parents and never turns into an
/// opaque white block; standalone cards use MoeContentSurface instead.
class MoeInsetSurface extends StatelessWidget {
  const MoeInsetSurface({
    super.key,
    this.child,
    this.radius = 0,
    this.border = BorderSide.none,
    this.padding,
  }) : assert(radius >= 0);

  final Widget? child;
  final double radius;
  final BorderSide border;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: moeInsetFill(Theme.of(context).brightness),
        shape: moeG2Shape(radius: radius, side: border),
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}
