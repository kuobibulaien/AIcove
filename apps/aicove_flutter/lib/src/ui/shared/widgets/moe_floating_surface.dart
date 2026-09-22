import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/tokens.dart';
import '../../theme/moe_frosted_material.dart';
import 'moe_liquid_glass.dart';
import 'moe_surface_motion.dart';

/// A clipped, translucent surface shared by phone and desktop chat controls.
class MoeFloatingSurface extends StatefulWidget {
  const MoeFloatingSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.blurSigma,
    this.baseline = MoeMaterialBaseline.none,
    this.blurEnabled,
    this.useLiquid,
    this.borderRadius,
    this.solidColor,
    this.border,
    this.shadows,
    this.padding,
  }) : assert(radius >= 0),
       assert(blurSigma == null || (blurSigma >= 0));

  final Widget child;
  final double radius;
  final double? blurSigma;

  /// Independent blur and tint minimums for this component.
  final MoeMaterialBaseline baseline;
  final bool? blurEnabled;

  /// 是否启用液态效果（为 null 时跟随全局设置 [MoeGlassTheme.useLiquidGlass]）
  final bool? useLiquid;
  final BorderRadius? borderRadius;
  final Color? solidColor;
  final BorderSide? border;
  final List<BoxShadow>? shadows;
  final EdgeInsetsGeometry? padding;

  @override
  State<MoeFloatingSurface> createState() => _MoeFloatingSurfaceState();
}

class _MoeFloatingSurfaceState extends State<MoeFloatingSurface> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _contentKey, child: widget.child);
    final radius = widget.radius;
    final blurSigma = widget.blurSigma;
    final baseline = widget.baseline;
    final blurEnabled = widget.blurEnabled;
    final useLiquid = widget.useLiquid;
    final borderRadius = widget.borderRadius;
    final solidColor = widget.solidColor;
    final border = widget.border;
    final shadows = widget.shadows;
    final padding = widget.padding;
    final colors = context.moeColors;
    final glassTheme = MoeGlassTheme.maybeOf(context);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final isBlurEnabled =
        (blurEnabled ?? glassTheme?.enabled ?? true) &&
        !moeSurfaceMovesWithContent(context) &&
        !highContrast &&
        !GlassAccessibilityData.of(context).reduceTransparency;
    final isFrosted = glassTheme?.material == MoeSurfaceMaterial.frosted;
    final brightness = Theme.of(context).brightness;
    final effectiveSigma = isFrosted
        ? MoeFrostedMaterial.blurSigmaForSetting(
            glassTheme?.blurSigma ?? kDefaultGlassBlurSigma,
          )
        : blurSigma ?? glassTheme?.blurSigma ?? kDefaultGlassBlurSigma;

    final isLiquid =
        !isFrosted &&
        (useLiquid ?? glassTheme?.useLiquidGlass ?? false) &&
        isBlurEnabled &&
        MoeLiquidGlassService.isAvailable;

    final content = padding == null
        ? child
        : Padding(padding: padding, child: child);
    if (isLiquid) {
      return MoeLiquidGlass(
        radius: radius,
        borderRadius: borderRadius,
        shadows: shadows,
        border: border,
        blurSigma: effectiveSigma,
        baseline: baseline,
        enabled: isBlurEnabled,
        child: content,
      );
    }

    final effectiveRadius = borderRadius ?? BorderRadius.circular(radius);

    final surfaceMaterial = Material(
      color: isBlurEnabled
          ? (isFrosted
                ? MoeFrostedMaterial.surfaceTint(brightness)
                : colors.glassTintForSigma(effectiveSigma, baseline: baseline))
          : (solidColor ?? colors.surface).withValues(alpha: 1),
      shape: RoundedRectangleBorder(
        borderRadius: effectiveRadius,
        side:
            border ??
            (isBlurEnabled
                ? colors.floatingBorder
                : BorderSide(
                    color: colors.borderLight.withValues(
                      alpha: colors.borderLight.a * 0.55,
                    ),
                    width: 0.6,
                  )),
      ),
      child: Ink(
        color: !isFrosted && baseline == MoeMaterialBaseline.text
            ? colors.textMaterialTint
            : Colors.transparent,
        child: content,
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: effectiveRadius,
        boxShadow: shadows ?? colors.floatingShadows,
      ),
      child: ClipRRect(
        borderRadius: effectiveRadius,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            if (isBlurEnabled && baseline.blurSigma(effectiveSigma) > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: isFrosted
                        ? MoeFrostedMaterial.surfaceFilter(
                            brightness,
                            sigma: effectiveSigma,
                          )
                        : ui.ImageFilter.blur(
                            sigmaX: baseline.blurSigma(effectiveSigma),
                            sigmaY: baseline.blurSigma(effectiveSigma),
                          ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            // Keep nested liquid surfaces outside the blur's compositing pass.
            // Its backdrop texture origin can differ from screen coordinates.
            surfaceMaterial,
          ],
        ),
      ),
    );
  }
}

/// Marks controls that share one surrounding material instead of stacking filters.
class MoeSurfaceGroup extends InheritedWidget {
  const MoeSurfaceGroup({super.key, required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeSurfaceGroup>() != null;
  @override
  bool updateShouldNotify(MoeSurfaceGroup oldWidget) => false;
}
