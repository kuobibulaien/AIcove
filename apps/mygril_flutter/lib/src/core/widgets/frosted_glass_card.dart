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
/// - 2025-12-25: 修复描边不生效与阴影被裁剪问题，增强卡片边角线条可见性
import 'dart:ui';
import 'package:flutter/material.dart';
import 'smooth_clip.dart';

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
  
  /// 圆角半径
  final double borderRadius;
  
  /// 模糊强度 (默认 25)
  final double blurSigma;
  
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
    this.borderRadius = 16,
    this.blurSigma = 25,
    this.boxShadow,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 使用 SmoothClipRRect 实现 iOS 风格平滑圆角
    // 阴影需要绘制在裁剪外层，否则会被 Clip 吞掉
    final card = Container(
      width: width,
      height: height,
      decoration: SmoothRectDecoration(
        radius: borderRadius,
        boxShadow: boxShadow ?? [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SmoothClipRRect(
        radius: borderRadius,
        child: Container(
          foregroundDecoration: SmoothRectDecoration(
            radius: borderRadius,
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.18)
                  : Colors.grey.shade400.withOpacity(0.35),
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
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[200],
                    ),
                  ),
                )
              else
                Container(
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.grey[200],
                ),

              // 2. 毛玻璃效果 (BackdropFilter)
              ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
                  child: Container(color: Colors.transparent),
                ),
              ),

              // 3. 轻微着色层（提升层次感）
              Container(
                color: isDark
                    ? Colors.black.withOpacity(0.3)  // 暗色模式：轻微压暗
                    : Colors.white.withOpacity(0.15), // 亮色模式：轻微提亮
              ),

              // 4. 内容层
              child,
            ],
          ),
        ),
      ),
    );

    if (onTap != null) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: card,
        ),
      );
    }

    return card;
  }
}

/// 毛玻璃容器 - 简单的半透明容器（不二次模糊，只做玻璃底色/描边）
///
/// 用于简介气泡、弹窗等场景
/// 注意：不再使用 BackdropFilter，避免与静态模糊背景叠加导致"里边更糊"
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 使用 SmoothClipRRect 实现 iOS 风格平滑圆角
    // 不使用 BackdropFilter，只做玻璃底色/描边
    return SmoothClipRRect(
      radius: borderRadius,
      child: Container(
        width: width,
        height: height,
        padding: padding,
        decoration: SmoothRectDecoration(
          radius: borderRadius,
          // 半透明底色（与外层背景融合）
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.32),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.white.withValues(alpha: 0.26),
            width: 0.5,
          ),
        ),
        child: child,
      ),
    );
  }
}
