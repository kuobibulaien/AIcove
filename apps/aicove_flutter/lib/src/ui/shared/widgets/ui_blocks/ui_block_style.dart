import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';

/// Colors and text styles of an interactive block, derived from the text
/// color around it so a block reads on bubbles and on the document page.
class UiBlockStyle {
  const UiBlockStyle({
    required this.fg,
    required this.accent,
    required this.fontSize,
    required this.positive,
    required this.negative,
    required this.warning,
    required this.info,
  });

  factory UiBlockStyle.of(
    BuildContext context, {
    Color? foregroundColor,
    double fontSize = 15,
  }) {
    final colors = context.moeColors;
    final fg = foregroundColor ?? colors.text;
    // Toast colors are tuned for light text on them; on a dark page lift
    // them so a tone used as text stays readable.
    final onDark = fg.computeLuminance() > 0.5;
    Color readable(Color color) =>
        onDark ? Color.lerp(color, Colors.white, 0.35)! : color;
    return UiBlockStyle(
      fg: fg,
      accent: colors.accentColor,
      fontSize: fontSize,
      positive: readable(colors.toastSuccess),
      negative: readable(colors.toastError),
      warning: readable(colors.toastWarning),
      info: readable(colors.toastInfo),
    );
  }

  final Color fg;
  final Color accent;
  final double fontSize;
  final Color positive;
  final Color negative;
  final Color warning;
  final Color info;

  Color get muted => fg.withValues(alpha: 0.58);
  Color get faint => fg.withValues(alpha: 0.08);
  Color get line => fg.withValues(alpha: 0.12);

  TextStyle get body => TextStyle(color: fg, fontSize: fontSize, height: 1.5);
  TextStyle get small =>
      TextStyle(color: fg, fontSize: fontSize - 2, height: 1.45);
  TextStyle get caption =>
      TextStyle(color: muted, fontSize: fontSize - 2.5, height: 1.4);
  TextStyle get title => TextStyle(
        color: fg,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        height: 1.4,
      );

  /// `tone` names the prompt allows; anything else is the plain text color.
  Color tone(Object? name) => switch (name) {
        'positive' || 'success' => positive,
        'negative' || 'error' || 'danger' => negative,
        'warning' || 'warn' => warning,
        'info' => info,
        'brand' || 'accent' => accent,
        'muted' => muted,
        _ => fg,
      };
}
