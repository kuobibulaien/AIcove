import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';

class MoeContentSurface extends StatefulWidget {
  const MoeContentSurface({
    super.key,
    required this.child,
    this.radius = MoeSettingsLayout.cardRadius,
    this.borderRadius,
    this.color,
    this.border = BorderSide.none,
    this.shadows = const [],
    this.padding,
    this.blurSigma = 0,
  }) : assert(radius >= 0),
       assert(blurSigma >= 0);

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final Color? color;
  final BorderSide border;
  final List<BoxShadow> shadows;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;

  @override
  State<MoeContentSurface> createState() => _MoeContentSurfaceState();
}

class _MoeContentSurfaceState extends State<MoeContentSurface> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _contentKey, child: widget.child);
    final colors = context.moeColors;
    final accessibilityReduced =
        (MediaQuery.maybeHighContrastOf(context) ?? false) ||
        GlassAccessibilityData.of(context).reduceTransparency;
    final blurAllowed =
        (MoeGlassTheme.maybeOf(context)?.enabled ?? true) &&
        !accessibilityReduced;
    final blurRequested = widget.blurSigma > 0;
    final blurActive = blurRequested && blurAllowed;
    final sigma = widget.blurSigma.clamp(0.0, kMaxContentSurfaceBlurSigma);
    final shape = moeG2Shape(
      radius: widget.radius,
      borderRadius: widget.borderRadius,
      side: widget.border,
    );
    final requestedColor = widget.color ?? colors.componentBackground;
    final effectiveColor =
        (accessibilityReduced || (blurRequested && !blurAllowed))
        ? requestedColor.withValues(alpha: 1)
        : requestedColor;
    final content = widget.padding == null
        ? child
        : Padding(padding: widget.padding!, child: child);

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: moeG2Shape(
          radius: widget.radius,
          borderRadius: widget.borderRadius,
        ),
        shadows: widget.shadows,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (blurActive)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Material(
              color: effectiveColor,
              shape: shape,
              child: content,
            ),
          ],
        ),
      ),
    );
  }
}
