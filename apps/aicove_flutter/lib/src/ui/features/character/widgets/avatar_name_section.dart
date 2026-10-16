/// AvatarNameSection - 角色编辑页：立绘海报区域
///
/// 立绘以海报展示（宽度占可用宽度的 0.618，宽高比 10:16），海报底部叠一枚「自定义」小胶囊；
/// 点击海报或胶囊都进入自定义形象页，更换立绘与头像。
///
/// 头像不再单独展示，但数据仍保留用于消息列表等场景。
///
/// 重构记录：
/// - 2025-12-31: 从 ContactEditPage 拆分，负责头像预览/选取 + 名称输入
/// - 2026-03-03: 合并头像和立绘区域，改为"大立绘 + 名称"垂直布局
/// - 2026-10-01: 名称输入移到页面标题栏
/// - 2026-10-14: 立绘改海报，去掉更换/清空按钮，底部改为「自定义」入口
/// - 2026-10-15: 海报宽高比 3:4 → 10:16，宽度系数 0.8 → 0.618
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

/// 海报占可用宽度的比例。
const double _kPosterWidthFactor = 0.618;

/// 海报宽高比。
const double _kPosterAspectRatio = 10 / 16;

/// 宽屏下海报的最大宽度，避免整窗铺满。
const double _kPosterMaxWidth = 400;
const double _kPosterRadius = 20;

class AvatarNameSection extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController avatarCtrl;
  final TextEditingController refImageCtrl;
  final VoidCallback onCustomize;

  const AvatarNameSection({
    super.key,
    required this.nameCtrl,
    required this.avatarCtrl,
    required this.refImageCtrl,
    required this.onCustomize,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    final helper = AvatarHelper(
      avatarUrl: avatarCtrl.text.trim().isEmpty ? null : avatarCtrl.text.trim(),
      characterImage: refImageCtrl.text.trim().isEmpty
          ? null
          : refImageCtrl.text.trim(),
      displayName: nameCtrl.text,
    );

    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SizedBox(
          width: math.min(
            constraints.maxWidth * _kPosterWidthFactor,
            _kPosterMaxWidth,
          ),
          child: AspectRatio(
            aspectRatio: _kPosterAspectRatio,
            child: GestureDetector(
              onTap: onCustomize,
              child: MoeG2ClipRRect(
                radius: _kPosterRadius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    helper.buildCharacterWidget(
                      fit: BoxFit.cover,
                      fallback: Container(
                        decoration: MoeG2Decoration(
                          radius: _kPosterRadius,
                          color: colors.surfaceAlt.withValues(alpha: 0.3),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.add_photo_alternate_outlined,
                          color: colors.muted,
                          size: 40,
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 14,
                      child: Center(
                        child: MoeFloatingSurface(
                          key: const ValueKey('character-customize'),
                          radius: 999,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 5,
                          ),
                          child: Text(
                            '自定义',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: colors.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
