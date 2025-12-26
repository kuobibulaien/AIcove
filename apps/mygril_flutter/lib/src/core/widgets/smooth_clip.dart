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
import 'package:flutter/material.dart';

/// 平滑圆角裁剪容器
/// 
/// 使用 ContinuousRectangleBorder 实现 iOS 风格的平滑圆角
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

/// iOS 风格平滑圆角裁剪器
/// 
/// 系数 2.35 是经验值，用于将标准圆角值转换为 ContinuousRectangleBorder 所需的值，
/// 使视觉效果与 iOS 的 UIBezierPath 一致。
class SmoothRectClipper extends CustomClipper<Path> {
  /// 圆角半径（与标准 BorderRadius 使用相同的值）
  final double radius;
  
  /// 转换系数：ContinuousRectangleBorder 需要更大的值才能达到相同的视觉效果
  static const double _conversionFactor = 2.35;
  
  SmoothRectClipper({required this.radius});
  
  @override
  Path getClip(Size size) {
    final shape = ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(radius * _conversionFactor),
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
}

class _SmoothRectPainter extends BoxPainter {
  final SmoothRectDecoration _decoration;

  _SmoothRectPainter(this._decoration, VoidCallback? onChanged) : super(onChanged);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(_decoration.radius * SmoothRectClipper._conversionFactor),
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
