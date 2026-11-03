import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/moe_frosted_material.dart';
import '../../theme/tokens.dart';
import '../effects/smooth_clip.dart';
import 'moe_floating_surface.dart';
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
    final fill = _ContentFill.resolve(context, widget.color);
    final paddedContent = widget.padding == null
        ? child
        : Padding(padding: widget.padding!, child: child);
    final content = MoeSolidBackdropScope(
      color: fill.color.a >= 1.0 ? fill.color : null,
      child: fill.filter != null
          ? MoeSharedBackdrop.isolate(child: paddedContent)
          : paddedContent,
    );
    if (fill.liquid) {
      // Match the floating bars: same component blur and the glass rim. The
      // hairline content border is for opaque cards and would hide the rim.
      return MoeLiquidGlass(
        radius: widget.radius,
        borderRadius: widget.borderRadius,
        shadows: widget.shadows,
        keepPremiumWhileScrolling: !Platform.isAndroid && !Platform.isIOS,
        solidBackdrop: fill.solidBackdrop,
        child: content,
      );
    }
    final shape = moeG2Shape(
      radius: widget.radius,
      borderRadius: widget.borderRadius,
      side: widget.border,
    );

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
            if (fill.filter != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    backdropGroupKey: MoeSharedBackdrop.keyOf(context),
                    filter: fill.filter!,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Material(color: fill.color, shape: shape, child: content),
          ],
        ),
      ),
    );
  }
}

/// Sliver counterpart of [MoeContentSurface] for long lazy lists: one card
/// behind [sliver] that keeps its rows built on demand. Solid and frosted
/// match the box surface; glass falls back to frosted, since the liquid
/// shader needs a box.
class MoeSliverContentSurface extends StatelessWidget {
  const MoeSliverContentSurface({
    super.key,
    required this.sliver,
    this.radius = MoeSettingsLayout.cardRadius,
    this.border = BorderSide.none,
  }) : assert(radius >= 0);

  final Widget sliver;
  final double radius;
  final BorderSide border;

  @override
  Widget build(BuildContext context) {
    final fill = _ContentFill.resolve(context, null, allowLiquid: false);
    final scopedSliver = MoeSolidBackdropScope(
      color: fill.color.a >= 1.0 ? fill.color : null,
      child: fill.filter != null
          ? MoeSharedBackdrop.isolate(child: sliver)
          : sliver,
    );
    return _SliverContentSurface(
      color: fill.color,
      filter: fill.filter,
      backdropKey: MoeSharedBackdrop.keyOf(context),
      shape: moeG2Shape(radius: radius, side: border),
      sliver: scopedSliver,
    );
  }
}

/// Fill of a default content card: [filter] is the backdrop blur when the
/// card follows a translucent global material.
class _ContentFill {
  const _ContentFill({
    required this.color,
    this.filter,
    this.liquid = false,
    this.solidBackdrop,
  });

  factory _ContentFill.resolve(
    BuildContext context,
    Color? explicit, {
    bool allowLiquid = true,
  }) {
    final colors = context.moeColors;
    final glassTheme = MoeGlassTheme.maybeOf(context);
    final accessibilityReduced =
        (MediaQuery.maybeHighContrastOf(context) ?? false) ||
        GlassAccessibilityData.of(context).reduceTransparency;
    final material = glassTheme?.material ?? MoeSurfaceMaterial.solid;
    final brightness = Theme.of(context).brightness;
    // Default cards carry a faint ink layer so they read as a distinct
    // surface instead of a white block; in the frosted branch the result
    // stays translucent so the backdrop blur still shows through.
    final ink = explicit == null
        ? moeContentSurfaceInk(brightness)
        : const Color(0x00000000);
    if (explicit == null &&
        material != MoeSurfaceMaterial.solid &&
        !accessibilityReduced) {
      final tintFill = glassTheme!.tintFill;
      final translucentTint = Color.alphaBlend(
        ink,
        MoeFrostedMaterial.surfaceTint(brightness, fill: tintFill),
      );
      final isLiquid = allowLiquid && material == MoeSurfaceMaterial.liquid;
      final solidBackdrop = MoeSolidBackdropScope.colorOf(context);
      if (solidBackdrop != null) {
        final saturatedBackdrop = MoeFrostedMaterial.saturateColor(
          brightness,
          solidBackdrop,
          fill: tintFill,
        );
        return _ContentFill(
          liquid: isLiquid,
          color: Color.alphaBlend(translucentTint, saturatedBackdrop),
          solidBackdrop: solidBackdrop,
        );
      }
      return _ContentFill(
        liquid: isLiquid,
        color: translucentTint,
        filter: MoeFrostedMaterial.surfaceFilter(
          brightness,
          sigma: MoeFrostedMaterial.blurSigmaForSetting(glassTheme.blurSigma),
          fill: tintFill,
        ),
      );
    }
    final requested = Color.alphaBlend(
      ink,
      explicit ?? colors.componentBackground,
    );
    return _ContentFill(
      color: accessibilityReduced ? requested.withValues(alpha: 1) : requested,
    );
  }

  final Color color;
  final ui.ImageFilter? filter;
  final bool liquid;
  final Color? solidBackdrop;
}

class _SliverContentSurface extends SingleChildRenderObjectWidget {
  const _SliverContentSurface({
    required this.color,
    required this.filter,
    required this.backdropKey,
    required this.shape,
    required Widget sliver,
  }) : super(child: sliver);

  final Color color;
  final ui.ImageFilter? filter;
  final BackdropKey? backdropKey;
  final ShapeBorder shape;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverContentSurface(
        color: color,
        filter: filter,
        backdropKey: backdropKey,
        shape: shape,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverContentSurface renderObject,
  ) {
    renderObject
      ..color = color
      ..filter = filter
      ..backdropKey = backdropKey
      ..shape = shape;
  }
}

/// Clips to the card shape over the sliver's whole scroll extent, blurs the
/// visible part of the backdrop, then paints fill, rows and border.
class _RenderSliverContentSurface extends RenderProxySliver {
  _RenderSliverContentSurface({
    required this._color,
    required this._filter,
    required this._backdropKey,
    required this._shape,
  });

  final _clipLayer = LayerHandle<ClipPathLayer>();
  final _filterLayer = LayerHandle<BackdropFilterLayer>();

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  ui.ImageFilter? _filter;
  set filter(ui.ImageFilter? value) {
    if (value == _filter) return;
    if ((value == null) != (_filter == null)) {
      markNeedsCompositingBitsUpdate();
    }
    _filter = value;
    markNeedsPaint();
  }

  BackdropKey? _backdropKey;
  set backdropKey(BackdropKey? value) {
    if (value == _backdropKey) return;
    _backdropKey = value;
    markNeedsPaint();
  }

  ShapeBorder _shape;
  set shape(ShapeBorder value) {
    if (value == _shape) return;
    _shape = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _filter != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    final geometry = this.geometry!;
    if (child == null || !geometry.visible) {
      _clipLayer.layer = null;
      _filterLayer.layer = null;
      return;
    }
    assert(constraints.axisDirection == AxisDirection.down);
    final card = Rect.fromLTWH(
      0,
      -constraints.scrollOffset,
      constraints.crossAxisExtent,
      geometry.scrollExtent,
    );
    final path = _shape.getOuterPath(card);

    void paintCard(PaintingContext context, Offset offset) {
      context.canvas.drawPath(path.shift(offset), Paint()..color = _color);
      context.paintChild(child, offset);
      _shape.paint(context.canvas, card.shift(offset));
    }

    _clipLayer.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & Size(constraints.crossAxisExtent, geometry.paintExtent),
      path,
      (context, offset) {
        final filter = _filter;
        if (filter == null) {
          _filterLayer.layer = null;
          paintCard(context, offset);
          return;
        }
        final layer = (_filterLayer.layer ??= BackdropFilterLayer())
          ..backdropKey = _backdropKey
          ..filter = filter;
        context.pushLayer(layer, paintCard, offset);
      },
      oldLayer: _clipLayer.layer,
    );
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    _filterLayer.layer = null;
    super.dispose();
  }
}
