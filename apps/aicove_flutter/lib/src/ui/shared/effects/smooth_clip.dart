/// iOS 风格平滑圆角组件（Squircle/Continuous Corner）
///
/// 提供与 iOS 视觉一致的平滑圆角效果，区别于 Flutter 默认的圆角。
///
/// 使用方法：
/// ```dart
/// SmoothClipRRect(
///   radius: 12.0,
///   child: YourWidget(),
/// )
/// ```
///
/// 更新记录：
/// - 2025-12-03: 创建，用于表情包管理页面的展开动画
/// - 2025-12-25: 修复 SmoothRectDecoration 未绘制 border 的问题（描边生效）
/// - 2026-01-22: 新增 Figma G2 连续曲线圆角组件（MoeG2ClipRRect / MoeG2Decoration）
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;

import 'package:flutter/material.dart';
import 'package:figma_squircle/figma_squircle.dart';

/// 平滑圆角裁剪容器（兼容旧命名）
/// 
/// 内部使用 Figma G2 圆角路径（MoeG2ClipRRect）。
class SmoothClipRRect extends StatelessWidget {
  /// 圆角半径
  final double radius;
  
  /// 子组件
  final Widget child;

  const SmoothClipRRect({
    super.key,
    required this.radius,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: SmoothRectClipper(radius: radius),
      child: child,
    );
  }
}

/// 平滑圆角裁剪器（兼容旧命名）
/// 
/// 内部使用 Figma G2 圆角路径。
class SmoothRectClipper extends CustomClipper<Path> {
  /// 圆角半径（与标准 BorderRadius 使用相同的值）
  final double radius;

  SmoothRectClipper({required this.radius});
  
  @override
  Path getClip(Size size) {
    final shape = SmoothRectangleBorder(
      borderRadius: SmoothBorderRadius.all(
        SmoothRadius(cornerRadius: radius, cornerSmoothing: 0.6),
      ),
    );
    return shape.getOuterPath(Rect.fromLTWH(0, 0, size.width, size.height));
  }
  
  @override
  bool shouldReclip(SmoothRectClipper oldClipper) => oldClipper.radius != radius;
}

/// 平滑圆角装饰（用于 Container.decoration）
/// 
/// 注意：此装饰只影响背景绘制，不会裁剪子组件。
/// 如需裁剪效果，请使用 SmoothClipRRect 包裹。
class SmoothRectDecoration extends Decoration {
  final double radius;
  final Color? color;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;

  const SmoothRectDecoration({
    required this.radius,
    this.color,
    this.border,
    this.boxShadow,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _SmoothRectPainter(this, onChanged);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SmoothRectDecoration &&
        other.radius == radius &&
        other.color == color &&
        other.border == border &&
        listEquals(other.boxShadow, boxShadow);
  }

  @override
  int get hashCode => Object.hash(
        radius,
        color,
        border,
        boxShadow == null ? null : Object.hashAll(boxShadow!),
      );
}

class _SmoothRectPainter extends BoxPainter {
  final SmoothRectDecoration _decoration;

  _SmoothRectPainter(this._decoration, VoidCallback? onChanged) : super(onChanged);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = SmoothRectangleBorder(
      borderRadius: SmoothBorderRadius.all(
        SmoothRadius(cornerRadius: _decoration.radius, cornerSmoothing: 0.6),
      ),
    );
    final path = shape.getOuterPath(rect);

    // 绘制阴影
    if (_decoration.boxShadow != null) {
      for (final shadow in _decoration.boxShadow!) {
        final shadowPath = path.shift(shadow.offset);
        canvas.drawShadow(shadowPath, shadow.color, shadow.blurRadius, false);
      }
    }

    // 绘制背景
    if (_decoration.color != null) {
      canvas.drawPath(path, Paint()..color = _decoration.color!);
    }

    // 绘制描边
    if (_decoration.border != null) {
      final border = _decoration.border!;
      if (border is Border && border.isUniform) {
        final side = border.top;
        if (side.style != BorderStyle.none && side.width > 0) {
          final borderRect = rect.deflate(side.width / 2);
          if (borderRect.width > 0 && borderRect.height > 0) {
            final borderPath = shape.getOuterPath(borderRect);
            canvas.drawPath(
              borderPath,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = side.width
                ..color = side.color,
            );
          }
        }
      }
    }
  }
}

// ============================================================================
// Figma G2 连续曲线圆角（推荐使用）
// ============================================================================

/// Figma 风格 G2 连续曲线圆角裁剪容器
///
/// 使用 figma_squircle 库实现真正的 G2 曲率连续圆角，视觉最柔和。
/// 推荐作为项目标准圆角使用。
///
/// ```dart
/// MoeG2ClipRRect(
///   radius: 20,
///   child: YourWidget(),
/// )
/// ```
class MoeG2ClipRRect extends StatelessWidget {
  final double radius;

  /// 平滑度（0-1，Figma 默认 0.6）（兼容旧用法）
  final double smoothing;

  /// 支持非对称（仅顶部圆角等）的 G2 圆角
  final SmoothBorderRadius borderRadius;

  final Widget child;

  MoeG2ClipRRect({
    super.key,
    required this.radius,
    this.smoothing = 0.6,
    required this.child,
  }) : borderRadius = SmoothBorderRadius.all(
          SmoothRadius(cornerRadius: radius, cornerSmoothing: smoothing),
        );

  /// 使用自定义的 G2 圆角（支持仅顶部圆角等非对称场景）
  MoeG2ClipRRect.borderRadius({
    super.key,
    required this.borderRadius,
    required this.child,
  })  : radius = borderRadius.topLeft.cornerRadius,
        smoothing = borderRadius.topLeft.cornerSmoothing;

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _G2RectClipper(
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }
}

class _G2RectClipper extends CustomClipper<Path> {
  final SmoothBorderRadius borderRadius;

  _G2RectClipper({required this.borderRadius});

  @override
  Path getClip(Size size) {
    return SmoothRectangleBorder(
      borderRadius: borderRadius,
    ).getOuterPath(Rect.fromLTWH(0, 0, size.width, size.height));
  }

  @override
  bool shouldReclip(_G2RectClipper oldClipper) => oldClipper.borderRadius != borderRadius;
}

/// Figma 风格 G2 连续曲线圆角装饰
///
/// 用于 Container.decoration，支持背景色、边框、阴影。
///
/// ```dart
/// Container(
///   decoration: MoeG2Decoration(
///     radius: 20,
///     color: Colors.white,
///     border: Border.all(color: Colors.grey),
///   ),
/// )
/// ```
class MoeG2Decoration extends Decoration {
  final SmoothBorderRadius borderRadius;
  final Color? color;
  final BoxBorder? border;
  final List<BoxShadow>? boxShadow;

  MoeG2Decoration({
    required this.radius,
    this.smoothing = 0.6,
    this.color,
    this.border,
    this.boxShadow,
  }) : borderRadius = SmoothBorderRadius.all(
          SmoothRadius(cornerRadius: radius, cornerSmoothing: smoothing),
        );

  /// 使用自定义的 G2 圆角（支持仅顶部圆角等非对称场景）
  MoeG2Decoration.borderRadius({
    required this.borderRadius,
    this.color,
    this.border,
    this.boxShadow,
  })  : radius = borderRadius.topLeft.cornerRadius,
        smoothing = borderRadius.topLeft.cornerSmoothing;

  /// 统一圆角半径（兼容旧用法）
  final double radius;

  /// 平滑度（0-1，Figma 默认 0.6）（兼容旧用法）
  final double smoothing;

  @override
  Decoration? lerpFrom(Decoration? a, double t) {
    if (a is MoeG2Decoration) {
      return MoeG2Decoration._lerp(a, this, t);
    }
    return super.lerpFrom(a, t);
  }

  @override
  Decoration? lerpTo(Decoration? b, double t) {
    if (b is MoeG2Decoration) {
      return MoeG2Decoration._lerp(this, b, t);
    }
    return super.lerpTo(b, t);
  }

  static MoeG2Decoration _lerp(MoeG2Decoration a, MoeG2Decoration b, double t) {
    return MoeG2Decoration.borderRadius(
      borderRadius: _lerpSmoothBorderRadius(a.borderRadius, b.borderRadius, t),
      color: Color.lerp(a.color, b.color, t),
      border: BoxBorder.lerp(a.border, b.border, t),
      boxShadow: BoxShadow.lerpList(a.boxShadow, b.boxShadow, t),
    );
  }

  static SmoothBorderRadius _lerpSmoothBorderRadius(
    SmoothBorderRadius a,
    SmoothBorderRadius b,
    double t,
  ) {
    return SmoothBorderRadius.only(
      topLeft: _lerpSmoothRadius(a.topLeft, b.topLeft, t),
      topRight: _lerpSmoothRadius(a.topRight, b.topRight, t),
      bottomLeft: _lerpSmoothRadius(a.bottomLeft, b.bottomLeft, t),
      bottomRight: _lerpSmoothRadius(a.bottomRight, b.bottomRight, t),
    );
  }

  static SmoothRadius _lerpSmoothRadius(SmoothRadius a, SmoothRadius b, double t) {
    return SmoothRadius(
      cornerRadius: lerpDouble(a.cornerRadius, b.cornerRadius, t) ?? b.cornerRadius,
      cornerSmoothing: lerpDouble(a.cornerSmoothing, b.cornerSmoothing, t) ?? b.cornerSmoothing,
    );
  }

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _G2RectPainter(this, onChanged);
  }

  // Decoration 默认按引用比较；父组件每次 rebuild 都新建装饰实例，
  // RenderDecoratedBox 就会丢掉 painter 重画 squircle 路径。值相等让
  // 未变化的气泡装饰跳过重绘。
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MoeG2Decoration &&
        other.borderRadius == borderRadius &&
        other.color == color &&
        other.border == border &&
        listEquals(other.boxShadow, boxShadow);
  }

  @override
  int get hashCode => Object.hash(
        borderRadius,
        color,
        border,
        boxShadow == null ? null : Object.hashAll(boxShadow!),
      );
}

class _G2RectPainter extends BoxPainter {
  final MoeG2Decoration _decoration;

  _G2RectPainter(this._decoration, VoidCallback? onChanged) : super(onChanged);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = SmoothRectangleBorder(
      borderRadius: _decoration.borderRadius,
    );
    final path = shape.getOuterPath(rect);

    // 绘制阴影
    if (_decoration.boxShadow != null) {
      for (final shadow in _decoration.boxShadow!) {
        final shadowPath = path.shift(shadow.offset);
        canvas.drawShadow(shadowPath, shadow.color, shadow.blurRadius, false);
      }
    }

    // 绘制背景
    if (_decoration.color != null) {
      canvas.drawPath(path, Paint()..color = _decoration.color!);
    }

    // 绘制描边
    if (_decoration.border != null) {
      final border = _decoration.border!;
      if (border is Border && border.isUniform) {
        final side = border.top;
        if (side.style != BorderStyle.none && side.width > 0) {
          final borderRect = rect.deflate(side.width / 2);
          if (borderRect.width > 0 && borderRect.height > 0) {
            final borderPath = shape.getOuterPath(borderRect);
            canvas.drawPath(
              borderPath,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = side.width
                ..color = side.color,
            );
          }
        }
      }
    }
  }
}
