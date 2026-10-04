/// 毛玻璃卡片组件 - 纯高斯模糊效果
///
/// 用法示例：
/// ```dart
/// FrostedGlassCard(
///   imageProvider: AssetImage('assets/characters/Arona.webp'),
///   child: Text('内容'),
/// )
/// ```
///
/// 更新记录：
/// - 2025-12-07: 从 role_card_page.dart 抽取，简化为纯毛玻璃效果
/// - 2025-12-07: 改用 SmoothClipRRect 实现 iOS 风格平滑圆角
/// - 2026-01-22: 圆角统一升级为 MoeG2ClipRRect / MoeG2Decoration（Figma G2 连续曲线）
/// - 2025-12-25: 修复描边不生效与阴影被裁剪问题，增强卡片边角线条可见性
library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import 'smooth_clip.dart';
import '../widgets/moe_floating_surface.dart';

/// 毛玻璃卡片 - 图片背景 + 高斯模糊
class FrostedGlassCard extends StatelessWidget {
  /// 背景图片 Provider
  final ImageProvider? imageProvider;

  /// 卡片内容
  final Widget child;

  /// 卡片宽度
  final double? width;

  /// 卡片高度
  final double? height;

  /// 圆角半径，默认 MoeSmoothRadii.md (20px)
  final double borderRadius;

  /// 局部模糊强度；默认跟随统一材质主题
  final double? blurSigma;

  /// 阴影
  final List<BoxShadow>? boxShadow;

  /// 点击回调
  final VoidCallback? onTap;

  const FrostedGlassCard({
    super.key,
    this.imageProvider,
    required this.child,
    this.width,
    this.height,
    this.borderRadius = MoeSmoothRadii.md,
    this.blurSigma,
    this.boxShadow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 使用 MoeG2ClipRRect / MoeG2Decoration 实现 G2 连续曲线圆角
    // 阴影需要绘制在裁剪外层，否则会被 Clip 吞掉
    final card = Container(
      width: width,
      height: height,
      decoration: MoeG2Decoration(
        radius: borderRadius,
        boxShadow:
            boxShadow ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
      ),
      child: MoeG2ClipRRect(
        radius: borderRadius,
        child: Container(
          foregroundDecoration: MoeG2Decoration(
            radius: borderRadius,
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.grey.shade400.withValues(alpha: 0.35),
              width: 1,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. 底层图片（放大避免边缘问题）
              if (imageProvider != null)
                Transform.scale(
                  scale: 1.2,
                  child: Image(
                    image: imageProvider!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: isDark
                          ? const Color(0xFF1E1E1E)
                          : Colors.grey[200],
                    ),
                  ),
                )
              else
                Container(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[200],
                ),

              MoeFloatingSurface(
                baseline: MoeMaterialBaseline.background,
                radius: borderRadius,
                blurSigma: MoeGlassTheme.maybeOf(context)?.blurSigma ?? blurSigma,
                shadows: const [],
                child: child,
              ),
            ],
          ),
        ),
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: card),
      );
    }

    return card;
  }
}

/// 历史容器入口，背景委托给统一三态材质。
///
/// 用于简介气泡、弹窗等场景
/// 新代码优先直接使用 MoeFloatingSurface。
class FrostedGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  const FrostedGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 12,
    this.padding,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: MoeFloatingSurface(
        baseline: MoeMaterialBaseline.background,
        radius: borderRadius,
        padding: padding,
        shadows: const [],
        child: child,
      ),
    );
  }
}
