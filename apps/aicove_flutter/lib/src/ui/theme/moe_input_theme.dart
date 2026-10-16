import 'package:flutter/material.dart';

import 'tokens.dart';

/// 输入框统一圆角，与 MoeTextField 默认值共用。
const double moeInputRadius = MoeRadii.md;

/// 全局输入框主题：未自绘外框的 TextField / TextFormField 默认使用。
///
/// 底色用半透明文字色叠加，而不是不透明白底：在纯色页面上是浅灰，
/// 在模糊弹层或壁纸上会透出背后颜色，不会出现突兀的白块。
/// 常态只有极淡描边，聚焦时换成主题色描边。
///
/// 各状态描边只放在一个随状态解析的 `border` 里，不设 enabled/focused 等分项：
/// 页面写了 `border: InputBorder.none`（含 `InputDecoration.collapsed`）时，
/// 整个主题描边都被替换，聚焦时也不会冒出主题描边。
InputDecorationTheme buildMoeInputDecorationTheme({
  required bool isDark,
  required Color accent,
}) {
  final ink = isDark ? Colors.white : moeText;
  final radius = BorderRadius.circular(moeInputRadius);
  MoeFilledInputBorder outline(Color color, [double width = 1]) =>
      MoeFilledInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: color, width: width),
      );

  return InputDecorationTheme(
    filled: true,
    fillColor: ink.withValues(alpha: isDark ? 0.06 : 0.04),
    visualDensity: VisualDensity.standard,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    hintStyle: TextStyle(color: isDark ? moeMutedDark : moeMuted),
    helperStyle: TextStyle(
      fontSize: 11,
      color: isDark ? moeMutedDark : moeMuted,
    ),
    border: _MoeStatefulInputBorder((states) {
      final focused = states.contains(WidgetState.focused);
      if (states.contains(WidgetState.disabled)) {
        return outline(ink.withValues(alpha: 0.03));
      }
      if (states.contains(WidgetState.error)) {
        return outline(moeToastError, focused ? 1.5 : 1);
      }
      if (focused) return outline(accent, 1.5);
      return outline(ink.withValues(alpha: isDark ? 0.08 : 0.06));
    }),
  );
}

/// 圆角描边，但按「填充型」排版：浮动标签落在框内左上角，
/// 而不是像 [OutlineInputBorder] 那样骑在上边框中间（半截露在底色外）。
class MoeFilledInputBorder extends OutlineInputBorder {
  const MoeFilledInputBorder({super.borderSide, super.borderRadius});

  @override
  bool get isOutline => false;

  /// InputDecorator 只要有标签就会传入缺口宽度，这里始终画完整描边。
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    super.paint(canvas, rect, textDirection: textDirection);
  }

  @override
  MoeFilledInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) {
    return MoeFilledInputBorder(
      borderSide: borderSide ?? this.borderSide,
      borderRadius: borderRadius ?? this.borderRadius,
    );
  }

  @override
  MoeFilledInputBorder scale(double t) => MoeFilledInputBorder(
        borderSide: borderSide.scale(t),
        borderRadius: borderRadius * t,
      );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is OutlineInputBorder) {
      return MoeFilledInputBorder(
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) {
    if (b is OutlineInputBorder) {
      return MoeFilledInputBorder(
        borderSide: BorderSide.lerp(borderSide, b.borderSide, t),
        borderRadius: BorderRadius.lerp(borderRadius, b.borderRadius, t)!,
      );
    }
    return super.lerpTo(b, t);
  }
}

class _MoeStatefulInputBorder extends MoeFilledInputBorder
    implements WidgetStateProperty<InputBorder> {
  const _MoeStatefulInputBorder(this._resolve) : super(borderSide: BorderSide.none);

  final MoeFilledInputBorder Function(Set<WidgetState>) _resolve;

  @override
  InputBorder resolve(Set<WidgetState> states) => _resolve(states);
}
