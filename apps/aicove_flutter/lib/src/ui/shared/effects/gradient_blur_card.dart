/// 功能入口卡片 - 公共组件
///
/// 用途：发现页顶部的快捷入口（如“我的角色卡”“定制角色卡”）
///
/// 设计目标：
/// - 类 QQ 的深色卡片按钮样式：纯色卡面 + 轻阴影 + 左上角图标 + 左下角标题/副标题
/// - 自动适配亮/暗色模式（颜色来自 theme tokens）
///
/// 更新记录：
/// - 2025-12-08: 从 role_card_page.dart 抽取为公共组件
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
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

  /// 卡片高度，默认 150 (适合竖向布局)
  final double height;

  /// 圆角半径，默认 24
  final double radius;

  const GradientBlurCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.height = 136,
    this.radius = MoeRadii.lg,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Container(
      height: height,
      decoration: MoeG2Decoration(
        radius: radius,
        boxShadow: MoeShadows.card,
      ),
      child: MoeG2ClipRRect(
        radius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: colors.accentColor.withValues(alpha: 0.10),
            highlightColor: colors.accentColor.withValues(alpha: 0.06),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 背景层
                DecoratedBox(
                  decoration: MoeG2Decoration(
                    radius: radius,
                    color: colors.componentBackground,
                    border: Border.all(
                      color: colors.borderLight.withValues(alpha: 0.7),
                      width: borderWidth,
                    ),
                  ),
                ),

                // 2. 内容层 - 垂直居中，左对齐
                Padding(
                  padding: const EdgeInsets.all(MoeSpacing.md),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：图标
                      Icon(icon, color: iconColor, size: 28),

                      const SizedBox(height: MoeSpacing.sm),

                      // 第二行：主标题（加粗）
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: MoeFontWeights.emphasis,
                          color: colors.text,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),

                      const SizedBox(height: MoeSpacing.xs),

                      // 第三行：副标题
                      Text(
                        subtitle ?? '',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.muted,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
