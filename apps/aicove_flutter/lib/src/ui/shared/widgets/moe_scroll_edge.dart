import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/moe_frosted_material.dart';
import '../../theme/tokens.dart';

/// Share of the surface tint the scroll edge keeps; the blur carries the
/// material, so the tint only lifts legibility.
const double kMoeScrollEdgeTintScale = 0.25;

/// Top padding that lets scroll content rest clear of a translucent bar and
/// then pass beneath it. [context] must be inside a Scaffold body that uses
/// `extendBodyBehindAppBar`; elsewhere the ambient top inset is zero.
EdgeInsets moeUnderBarPadding(
  BuildContext context, [
  EdgeInsets padding = EdgeInsets.zero,
]) => padding.copyWith(top: padding.top + MediaQuery.paddingOf(context).top);

/// Apple-style scroll edge for top bars: clear while content rests at its
/// leading edge. Once the nearest Scaffold's primary scroll view passes
/// beneath the bar, a progressive blur appears that is strongest at the top
/// edge and clears toward the floating controls' center line.
class MoeScrollEdgeBackdrop extends StatefulWidget {
  const MoeScrollEdgeBackdrop({
    super.key,
    required this.clearFromBottom,
    this.opaqueFallback = true,
  }) : assert(clearFromBottom >= 0);

  /// Distance from the bar's bottom to the floating controls' center line,
  /// where the blur has faded out.
  final double clearFromBottom;

  /// Whether solid or reduced-transparency surfaces fall back to an opaque
  /// bar. Bars whose controls all sit on their own opaque surfaces pass false
  /// and show nothing there instead.
  final bool opaqueFallback;

  @override
  State<MoeScrollEdgeBackdrop> createState() => _MoeScrollEdgeBackdropState();
}

class _MoeScrollEdgeBackdropState extends State<MoeScrollEdgeBackdrop> {
  ScrollNotificationObserverState? _observer;
  bool _scrolledUnder = false;

  /// Keeps the material built through its fade-out; resting bars build none.
  bool _painted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observer?.removeListener(_handleScroll);
    _observer = ScrollNotificationObserver.maybeOf(context);
    _observer?.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _observer?.removeListener(_handleScroll);
    super.dispose();
  }

  void _handleScroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification ||
        !defaultScrollNotificationPredicate(notification)) {
      return;
    }
    final metrics = notification.metrics;
    final scrolledUnder = switch (metrics.axisDirection) {
      AxisDirection.down => metrics.extentBefore > 0,
      // Reversed lists (chat) keep their older content above the viewport.
      AxisDirection.up => metrics.extentAfter > 0,
      _ => _scrolledUnder,
    };
    if (scrolledUnder != _scrolledUnder) {
      setState(() {
        _scrolledUnder = scrolledUnder;
        if (scrolledUnder) _painted = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final glass = MoeGlassTheme.maybeOf(context);
    final translucent =
        (glass?.enabled ?? true) &&
        !(MediaQuery.maybeHighContrastOf(context) ?? false) &&
        !GlassAccessibilityData.of(context).reduceTransparency;
    if (!translucent && !widget.opaqueFallback) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _scrolledUnder ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        onEnd: () {
          if (!_scrolledUnder && _painted) setState(() => _painted = false);
        },
        child: !_painted
            ? const SizedBox.expand()
            : translucent
            ? _ProgressiveEdge(
                material: glass?.material ?? MoeSurfaceMaterial.frosted,
                blurSetting: glass?.blurSigma ?? kDefaultGlassBlurSigma,
                tintFill: glass?.tintFill ?? kDefaultGlassTintFill,
                clearFromBottom: widget.clearFromBottom,
              )
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.headerColor,
                  border: Border(
                    bottom: BorderSide(
                      color: colors.divider,
                      width: borderWidth,
                    ),
                  ),
                ),
                child: const SizedBox.expand(),
              ),
      ),
    );
  }
}

/// Nested blur layers anchored at the top edge. Each shorter layer adds blur
/// and fades out through its own length, so blur accumulates toward the top
/// without hard steps or a sharp copy showing through.
class _ProgressiveEdge extends StatelessWidget {
  const _ProgressiveEdge({
    required this.material,
    required this.blurSetting,
    required this.tintFill,
    required this.clearFromBottom,
  });

  final MoeSurfaceMaterial material;
  final double blurSetting;
  final double tintFill;
  final double clearFromBottom;

  /// (share of the clear line covered, share of the full sigma). The squared
  /// shares sum to ~1, so the top edge reaches the full blur.
  static const _layers = [(1.0, 0.5), (0.66, 0.55), (0.33, 0.65)];

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final brightness = Theme.of(context).brightness;
    final frosted = material == MoeSurfaceMaterial.frosted;
    // Background material: readable blur minimum, tint follows the fill.
    final sigma = frosted
        ? MoeFrostedMaterial.blurSigmaForSetting(blurSetting)
        : MoeMaterialBaseline.background.blurSigma(blurSetting);
    final baseTint = frosted
        ? MoeFrostedMaterial.surfaceTint(brightness, fill: tintFill)
        : colors.glassTintForFill(tintFill);
    final tint = baseTint.withValues(
      alpha: baseTint.a * kMoeScrollEdgeTintScale,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final clearLine = (constraints.maxHeight - clearFromBottom).clamp(
          0.0,
          constraints.maxHeight,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            for (final (index, (reach, share)) in _layers.indexed)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: clearLine * reach,
                child: ClipRect(
                  child: BackdropFilter(
                    // Vibrancy only once: repeated saturation would band.
                    filter: frosted && index == 0
                        ? MoeFrostedMaterial.surfaceFilter(
                            brightness,
                            sigma: sigma * share,
                            tileMode: TileMode.mirror,
                          )
                        : ui.ImageFilter.blur(
                            sigmaX: sigma * share,
                            sigmaY: sigma * share,
                            // Mirroring keeps the window edge from blurring
                            // in empty backdrop.
                            tileMode: TileMode.mirror,
                          ),
                    child: CustomPaint(
                      painter: _EdgeFade(
                        index == 0 ? tint : Colors.transparent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Paints inside the filter layer so dstIn fades the blurred backdrop itself;
/// a separate ShaderMask would mask an empty buffer instead.
class _EdgeFade extends CustomPainter {
  const _EdgeFade(this.tint);

  final Color tint;

  static const _mask = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Colors.white,
      Color(0xE6FFFFFF),
      Color(0x99FFFFFF),
      Color(0x40FFFFFF),
      Color(0x00FFFFFF),
    ],
    stops: [0, 0.3, 0.6, 0.85, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (tint.a > 0) canvas.drawPaint(Paint()..color = tint);
    // Cover the whole clipped layer, including fractional edge pixels; a
    // bounds-sized rectangle leaves a partially unmasked seam.
    canvas.drawPaint(
      Paint()
        ..shader = _mask.createShader(Offset.zero & size)
        ..blendMode = BlendMode.dstIn,
    );
  }

  @override
  bool shouldRepaint(_EdgeFade oldDelegate) => oldDelegate.tint != tint;
}
