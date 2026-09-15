import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../theme/moe_interaction_theme.dart';
import '../../../theme/tokens.dart';

/// 统一数值滑块。
///
/// 胶囊轨道无视觉刻度点；[divisions] 只保留吸附语义，用于整数或档位取值。
/// 未传 [divisions] 时为无极调节。拖动时圆钮轻微放大。
class MoeSlider extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = SliderTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final thumbColor = isDark ? const Color(0xFFF2F2F7) : colors.surface;
    return SliderTheme(
      data: theme.copyWith(
        trackHeight: 6,
        trackShape: const _MoeSliderTrackShape(),
        thumbShape: const _MoeSliderThumbShape(),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        activeTrackColor: colors.accentColor,
        inactiveTrackColor: colors.accentColor.withValues(alpha: 0.15),
        disabledActiveTrackColor: colors.accentColor.withValues(alpha: 0.4),
        disabledInactiveTrackColor: colors.accentColor.withValues(alpha: 0.08),
        thumbColor: thumbColor,
        disabledThumbColor: thumbColor,
      ),
      child: Slider(
        overlayColor: moeInteractionOverlay,
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        semanticFormatterCallback: semanticFormatterCallback,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
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
      offset.dx,
      trackTop,
      parentBox.size.width,
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
  const _MoeSliderThumbShape();

  static const double _radius = 10;
  static const double _pressedRadius = 12.5;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_pressedRadius);

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
    final canvas = context.canvas;
    final r = ui.lerpDouble(
      _radius,
      _pressedRadius,
      activationAnimation.value,
    )!;
    final circle = Path()..addOval(Rect.fromCircle(center: center, radius: r));

    canvas.drawShadow(circle, Colors.black.withValues(alpha: 0.28), 3.5, true);
    canvas.drawPath(
      circle,
      Paint()
        ..color = Color.lerp(
          sliderTheme.disabledThumbColor,
          sliderTheme.thumbColor,
          enableAnimation.value,
        )!,
    );
    canvas.drawCircle(
      center,
      r - 0.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = Color.lerp(
          Colors.black.withValues(alpha: 0.08),
          sliderTheme.activeTrackColor!.withValues(alpha: 0.55),
          activationAnimation.value,
        )!,
    );
  }
}
