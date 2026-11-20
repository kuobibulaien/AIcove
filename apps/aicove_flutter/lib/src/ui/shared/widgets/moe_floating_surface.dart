import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/tokens.dart';
import '../../theme/moe_frosted_material.dart';
import '../effects/smooth_clip.dart';
import 'moe_liquid_glass.dart';
import 'moe_surface_motion.dart';

/// A clipped, translucent surface shared by phone and desktop chat controls.
class MoeFloatingSurface extends StatefulWidget {
  const MoeFloatingSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.blurSigma,
    this.baseline = MoeMaterialBaseline.component,
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

  /// Blur minimum of this layer; tint always follows the global fill.
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
    final isFrosted = glassTheme?.material == MoeSurfaceMaterial.frosted;
    final isBlurEnabled =
        (blurEnabled ?? glassTheme?.enabled ?? true) &&
        !moeSurfaceMovesWithContent(context, ignoreScrollables: true) &&
        !highContrast &&
        !GlassAccessibilityData.of(context).reduceTransparency;
    final brightness = Theme.of(context).brightness;
    final effectiveSigma = isFrosted
        ? MoeFrostedMaterial.blurSigmaForSetting(
            glassTheme?.blurSigma ?? kDefaultGlassBlurSigma,
          )
        : blurSigma ?? glassTheme?.blurSigma ?? kDefaultGlassBlurSigma;
    final tintFill = glassTheme?.tintFill ?? kDefaultGlassTintFill;

    final isLiquid =
        !isFrosted &&
        (useLiquid ?? glassTheme?.useLiquidGlass ?? false) &&
        isBlurEnabled &&
        MoeLiquidGlassService.isAvailable;

    final paddedContent = padding == null
        ? child
        : Padding(padding: padding, child: child);
    final content = isBlurEnabled
        ? MoeSolidBackdropScope.none(
            child: MoeSharedBackdrop.isolate(child: paddedContent),
          )
        : paddedContent;
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
    final maxCorner = [
      effectiveRadius.topLeft.x,
      effectiveRadius.topRight.x,
      effectiveRadius.bottomLeft.x,
      effectiveRadius.bottomRight.x,
    ].reduce((a, b) => a > b ? a : b);
    final effectiveSide =
        border ??
        (isBlurEnabled
            ? colors.floatingBorder
            : BorderSide(
                color: colors.borderLight.withValues(
                  alpha: colors.borderLight.a * 0.55,
                ),
                width: 0.6,
              ));
    final OutlinedBorder surfaceShape = maxCorner > 0 && maxCorner < 48
        ? moeG2Shape(
            radius: radius,
            borderRadius: effectiveRadius,
            side: effectiveSide,
          )
        : RoundedRectangleBorder(
            borderRadius: effectiveRadius,
            side: effectiveSide,
          );

    final surfaceMaterial = Material(
      color: isBlurEnabled
          ? (isFrosted
                ? MoeFrostedMaterial.surfaceTint(brightness, fill: tintFill)
                : colors.glassTintForFill(tintFill))
          : (solidColor ?? colors.componentBackground).withValues(alpha: 1),
      shape: surfaceShape,
      child: content,
    );

    final stack = Stack(
      fit: StackFit.passthrough,
      children: [
        // Frosted keeps its filter at zero blur: the vibrancy matrix
        // still follows the fill.
        if (isBlurEnabled &&
            (isFrosted || baseline.blurSigma(effectiveSigma) > 0))
          Positioned.fill(
            child: IgnorePointer(
              child: BackdropFilter(
                backdropGroupKey: MoeSharedBackdrop.keyOf(context),
                filter: isFrosted
                    ? MoeFrostedMaterial.surfaceFilter(
                        brightness,
                        sigma: effectiveSigma,
                        fill: tintFill,
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
    );

    final Widget clipped;
    if (maxCorner <= 0) {
      clipped = ClipRect(child: stack);
    } else if (surfaceShape is RoundedRectangleBorder) {
      clipped = ClipRRect(borderRadius: effectiveRadius, child: stack);
    } else {
      clipped = ClipPath(
        clipper: ShapeBorderClipper(
          shape: surfaceShape.copyWith(side: BorderSide.none),
        ),
        child: stack,
      );
    }

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: surfaceShape.copyWith(side: BorderSide.none),
        shadows: shadows ?? colors.floatingShadows,
      ),
      child: clipped,
    );
  }
}

/// Lets sibling surfaces over one backdrop read it once instead of once each.
///
/// For non-overlapping surfaces on the same layer with the same blur, such as
/// the three header capsules. The engine then blurs the backdrop once and each
/// surface cuts its share from that result, which samples slightly differently
/// than a per-surface blur (measured up to 5/255 per channel).
class MoeSharedBackdrop extends StatelessWidget {
  const MoeSharedBackdrop({super.key, required this.child}) : _enabled = true;

  /// Prevents descendants inside an already-blurred surface from sharing the
  /// ancestor's [BackdropKey], since overlapping filters must not share a key.
  const MoeSharedBackdrop.isolate({super.key, required this.child})
    : _enabled = false;

  final Widget child;
  final bool _enabled;

  static BackdropKey? keyOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_SharedBackdropScope>();
    if (scope == null || !scope.enabled) return null;
    return BackdropGroup.of(context)?.backdropKey;
  }

  @override
  Widget build(BuildContext context) => _enabled
      ? BackdropGroup(child: _SharedBackdropScope(enabled: true, child: child))
      : _SharedBackdropScope(enabled: false, child: child);
}

class _SharedBackdropScope extends InheritedWidget {
  const _SharedBackdropScope({required this.enabled, required super.child});

  final bool enabled;

  @override
  bool updateShouldNotify(_SharedBackdropScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// Marks controls that share one surrounding material instead of stacking filters.
class MoeSurfaceGroup extends InheritedWidget {
  const MoeSurfaceGroup({super.key, required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeSurfaceGroup>() != null;
  @override
  bool updateShouldNotify(MoeSurfaceGroup oldWidget) => false;
}

/// 浮在壁纸上的整页底色材质：宽屏左侧的根界面和桌面端通话小窗共用，
/// 完整跟随用户选的纯色／模糊／玻璃档；玻璃档走完全体液态玻璃，含透镜边缘。
class MoePageSurface extends StatelessWidget {
  const MoePageSurface({
    super.key,
    required this.child,
    this.radius = 0,
    this.blurEnabled,
  });

  final Widget child;
  final double radius;

  /// 见 [MoeFloatingSurface.blurEnabled]。
  final bool? blurEnabled;

  @override
  Widget build(BuildContext context) => MoeFloatingSurface(
    baseline: MoeMaterialBaseline.background,
    blurEnabled: blurEnabled,
    radius: radius,
    solidColor: context.moeColors.surface,
    border: BorderSide.none,
    shadows: const [],
    child: child,
  );
}
