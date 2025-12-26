/// 渐变高斯模糊卡片 - 公共组件
/// 
/// 用途：功能入口卡片，带粉白渐变 + 高斯模糊背景效果
/// 
/// 特点：
/// - 粉白渐变背景 + 高斯模糊
/// - 自动适配亮/暗色模式
/// - iOS 风格平滑圆角
/// 
/// 更新记录：
/// - 2025-12-08: 从 role_card_page.dart 抽取为公共组件
import 'dart:ui';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'smooth_clip.dart';

/// 渐变高斯模糊卡片
/// 
/// 用法：
/// ```dart
/// GradientBlurCard(
///   title: '我的角色卡',
///   subtitle: '3 个收藏',
///   icon: Icons.favorite,
///   iconColor: Colors.pinkAccent,
///   onTap: () => print('点击了'),
/// )
/// ```
class GradientBlurCard extends StatelessWidget {
  /// 标题
  final String title;
  
  /// 副标题（可选）
  final String? subtitle;
  
  /// 图标
  final IconData icon;
  
  /// 图标颜色
  final Color iconColor;
  
  /// 点击回调
  final VoidCallback onTap;
  
  /// 卡片高度，默认 80
  final double height;
  
  /// 圆角半径，默认 16
  final double radius;

  const GradientBlurCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.height = 80,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SmoothClipRRect(
      radius: radius,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: height,
            decoration: SmoothRectDecoration(
              radius: radius,
              border: Border.all(
                color: colors.borderLight.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 粉白渐变高斯模糊背景
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isDark
                            ? [const Color(0xFF2A1A2A), const Color(0xFF1A1A2A)]
                            : [
                                const Color(0xFFFFF0F5), // 极浅粉
                                const Color(0xFFF8F0FF), // 极浅紫
                                Colors.white,
                              ],
                        stops: isDark ? null : const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
                // 2. 半透明遮罩增强层次
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.4),
                        Colors.white.withOpacity(0.1),
                      ],
                    ),
                  ),
                ),
                // 3. 内容层
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      // 图标容器
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: iconColor.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: iconColor, size: 24),
                      ),
                      const SizedBox(width: 12),
                      // 文字区
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: colors.text,
                              ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.muted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
