import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../moe_floating_surface.dart';

/// Shared button material. Semantic colors tint the surface without hiding it.
class MoeButtonSurface extends StatelessWidget {
  const MoeButtonSurface({
    super.key,
    required this.child,
    this.tintColor,
    this.radius = 12,
    this.borderRadius,
    this.border,
    this.shadows,
    this.width,
    this.height,
    this.padding,
    this.margin,
    this.constraints,
    this.alignment,
    this.shareParentSurface = true,
  });

  final Widget child;
  final Color? tintColor;
  final double radius;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final List<BoxShadow>? shadows;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BoxConstraints? constraints;
  final AlignmentGeometry? alignment;

  /// Standalone action tiles keep their own material inside a larger panel.
  final bool shareParentSurface;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = tintColor ?? Colors.transparent;
    final effectiveRadius = borderRadius ?? BorderRadius.circular(radius);
    // Buttons inside one material surface share its backdrop and outer rim.
    // Keep semantic tint and explicit focus feedback without another glass pass.
    final sharesSurface =
        shareParentSurface &&
        context.findAncestorWidgetOfExactType<MoeFloatingSurface>() != null;
    final content = AnimatedContainer(
      duration: kAnimFast,
      padding: padding,
      alignment: alignment,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: tint.a.clamp(0, isDark ? 0.28 : 0.22)),
        borderRadius: effectiveRadius,
        border: border,
      ),
      child: child,
    );
    return Container(
      width: width,
      height: height,
      margin: margin,
      constraints: constraints,
      child: sharesSurface
          ? content
          : MoeFloatingSurface(
              borderRadius: effectiveRadius,
              border: border == null ? null : BorderSide.none,
              shadows: shadows,
              child: content,
            ),
    );
  }
}
