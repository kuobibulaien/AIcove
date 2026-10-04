import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../theme/moe_interaction_theme.dart';
import '../../../theme/tokens.dart';
import '../moe_liquid_glass.dart';

/// 统一数值滑块。
///
/// 胶囊轨道无视觉刻度点；[divisions] 只保留吸附语义，用于整数或档位取值。
/// 未传 [divisions] 时为无极调节。拖动时圆钮轻微放大。
class MoeSlider extends StatefulWidget {
  const MoeSlider({
    super.key,
    required this.value,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
    this.semanticFormatterCallback,
    this.onChanged,
    this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<MoeSlider> createState() => _MoeSliderState();
}

class _MoeSliderState extends State<MoeSlider> {
  final LayerLink _thumbLink = LayerLink()..leaderSize = Size.zero;
  bool _pressed = false;

  bool get _adjustable => widget.onChanged != null && widget.max > widget.min;

  void _handleChangeStart(double _) {
    if (!_adjustable || _pressed) return;
    setState(() => _pressed = true);
  }

  void _handleChangeEnd(double value) {
    if (_pressed) setState(() => _pressed = false);
    widget.onChangeEnd?.call(value);
  }

  @override
  void didUpdateWidget(MoeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_pressed && !_adjustable) {
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = SliderTheme.of(context);
    final inheritedVertical = theme.padding?.resolve(
      Directionality.of(context),
    );
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          height: 48,
          child: _MoeSliderComposited(
            child: SliderTheme(
              data: theme.copyWith(
                trackHeight: 6,
                padding: EdgeInsets.only(
                  top: inheritedVertical?.top ?? 0,
                  bottom: inheritedVertical?.bottom ?? 0,
                ),
                trackShape: const _MoeSliderTrackShape(),
                thumbShape: _MoeSliderThumbShape(link: _thumbLink),
                tickMarkShape: SliderTickMarkShape.noTickMark,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                activeTrackColor: colors.accentColor,
                inactiveTrackColor: colors.accentColor.withValues(alpha: 0.15),
                disabledActiveTrackColor: colors.accentColor.withValues(
                  alpha: 0.4,
                ),
                disabledInactiveTrackColor: colors.accentColor.withValues(
                  alpha: 0.08,
                ),
              ),
              child: Slider(
                overlayColor: moeInteractionOverlay,
                value: widget.value,
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                label: widget.label,
                semanticFormatterCallback: widget.semanticFormatterCallback,
                onChanged: widget.onChanged,
                onChangeStart: _handleChangeStart,
                onChangeEnd: _handleChangeEnd,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CompositedTransformFollower(
            link: _thumbLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.center,
            followerAnchor: Alignment.center,
            child: Center(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: AnimatedScale(
                    key: const ValueKey('moe-slider-thumb'),
                    scale: _pressed ? 1.25 : 1,
                    duration: disableAnimations ? Duration.zero : kAnimFast,
                    child: SizedBox(
                      width: 32,
                      height: 24,
                      child: MoeLiquidGlass(
                        enabled:
                            MoeGlassTheme.maybeOf(context)?.enabled ?? true,
                        quality: GlassQuality.standard,
                        radius: 8,
                        baseline: MoeMaterialBaseline.component,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MoeSliderComposited extends SingleChildRenderObjectWidget {
  const _MoeSliderComposited({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MoeSliderCompositedRenderBox();
}

class _MoeSliderCompositedRenderBox extends RenderProxyBox {
  @override
  bool get alwaysNeedsCompositing => true;
}

/// 整根胶囊轨道：非激活段薄染色，激活段纵向微光泽渐变。
class _MoeSliderTrackShape extends SliderTrackShape {
  const _MoeSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 6;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(
      offset.dx + 20,
      trackTop,
      math.max(0, parentBox.size.width - 40),
      trackHeight,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final canvas = context.canvas;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(trackRect.height / 2);
    final trackRRect = RRect.fromRectAndRadius(trackRect, radius);

    final activeColor = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final inactiveColor = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;

    canvas.drawRRect(trackRRect, Paint()..color = inactiveColor);

    final activeLeft = textDirection == TextDirection.ltr
        ? trackRect.left
        : thumbCenter.dx;
    final activeRight = textDirection == TextDirection.ltr
        ? thumbCenter.dx
        : trackRect.right;
    if (activeRight <= activeLeft) return;

    canvas.save();
    canvas.clipRRect(trackRRect);
    canvas.drawRect(
      Rect.fromLTRB(activeLeft, trackRect.top, activeRight, trackRect.bottom),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(activeColor, Colors.white, 0.22)!, activeColor],
        ).createShader(trackRect),
    );
    canvas.restore();
  }
}

/// 悬浮圆钮：表面色填充、发丝描边、柔和投影，激活时放大并提亮描边。
class _MoeSliderThumbShape extends SliderComponentShape {
  _MoeSliderThumbShape({required this.link});

  final LayerLink link;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(40, 30);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Matrix4 transform = Matrix4.fromFloat64List(
      context.canvas.getTransform(),
    );
    final Offset containerCenter = MatrixUtils.transformPoint(
      transform,
      center,
    );
    context.addLayer(LeaderLayer(link: link)..offset = containerCenter);
  }
}
