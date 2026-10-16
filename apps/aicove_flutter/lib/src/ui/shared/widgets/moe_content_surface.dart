import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/moe_frosted_material.dart';
import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';
import 'moe_liquid_glass.dart';

/// Ink layered over default content cards in every material.
Color moeContentSurfaceInk(Brightness brightness) =>
    brightness == Brightness.dark
    ? const Color(0x10FFFFFF)
    : const Color(0x0E222222);

/// Solid-material fill of a default content card.
Color moeContentSurfaceSolidColor(MoeColors colors, Brightness brightness) =>
    Color.alphaBlend(
      moeContentSurfaceInk(brightness),
      colors.componentBackground,
    );

/// Content cards follow the global material as a page-wide default: solid
/// stays opaque, frosted uses the same thick blur as floating controls, and
/// glass renders the same liquid lens and rim as the floating bars, keeping
/// the premium shader even inside scroll views.
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
  }) : assert(radius >= 0);

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;

  /// Explicit fill; when set the surface stays a plain fill without blur.
  final Color? color;
  final BorderSide border;
  final List<BoxShadow> shadows;
  final EdgeInsetsGeometry? padding;

  @override
  State<MoeContentSurface> createState() => _MoeContentSurfaceState();
}

class _MoeContentSurfaceState extends State<MoeContentSurface> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _contentKey, child: widget.child);
    final colors = context.moeColors;
    final glassTheme = MoeGlassTheme.maybeOf(context);
    final accessibilityReduced =
        (MediaQuery.maybeHighContrastOf(context) ?? false) ||
        GlassAccessibilityData.of(context).reduceTransparency;
    final material = glassTheme?.material ?? MoeSurfaceMaterial.solid;
    final followsMaterial =
        widget.color == null &&
        material != MoeSurfaceMaterial.solid &&
        !accessibilityReduced;
    final brightness = Theme.of(context).brightness;
    final tintFill = glassTheme?.tintFill ?? kDefaultGlassTintFill;
    final content = widget.padding == null
        ? child
        : Padding(padding: widget.padding!, child: child);
    if (followsMaterial && material == MoeSurfaceMaterial.liquid) {
      // Match the floating bars: same component blur and the glass rim. The
      // hairline content border is for opaque cards and would hide the rim.
      return MoeLiquidGlass(
        radius: widget.radius,
        borderRadius: widget.borderRadius,
        shadows: widget.shadows,
        keepPremiumWhileScrolling: true,
        child: content,
      );
    }
    final sigma = MoeFrostedMaterial.blurSigmaForSetting(
      glassTheme?.blurSigma ?? kDefaultGlassBlurSigma,
    );
    final shape = moeG2Shape(
      radius: widget.radius,
      borderRadius: widget.borderRadius,
      side: widget.border,
    );
    // Default cards carry a faint ink layer so they read as a distinct
    // surface instead of a white block; in the frosted branch the result
    // stays translucent so the backdrop blur still shows through.
    final ink = widget.color == null
        ? moeContentSurfaceInk(brightness)
        : const Color(0x00000000);
    final requestedColor = Color.alphaBlend(
      ink,
      widget.color ?? colors.componentBackground,
    );
    final effectiveColor = followsMaterial
        ? Color.alphaBlend(
            ink,
            MoeFrostedMaterial.surfaceTint(brightness, fill: tintFill),
          )
        : accessibilityReduced
        ? requestedColor.withValues(alpha: 1)
        : requestedColor;

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
            if (followsMaterial)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: MoeFrostedMaterial.surfaceFilter(
                      brightness,
                      sigma: sigma,
                      fill: tintFill,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Material(color: effectiveColor, shape: shape, child: content),
          ],
        ),
      ),
    );
  }
}
