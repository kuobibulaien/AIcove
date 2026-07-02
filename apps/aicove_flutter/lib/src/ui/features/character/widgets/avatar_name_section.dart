/// AvatarNameSection - 角色编辑页：立绘 + 名称区域
///
/// 合并了原来的头像区域和立绘区域，改为：
/// - 上方：无边框大立绘图（宽度约占屏幕50%）
/// - 中间：角色名称输入框（居中）
/// - 下方：更换/清空立绘操作按钮
///
/// 头像不再单独展示，但数据仍保留用于消息列表等场景。
///
/// 重构记录：
/// - 2025-12-31: 从 ContactEditPage 拆分，负责头像预览/选取 + 名称输入
/// - 2026-03-03: 合并头像和立绘区域，改为"大立绘 + 名称"垂直布局
library;

import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';

class AvatarNameSection extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController avatarCtrl;
  final TextEditingController refImageCtrl;
  final VoidCallback onPickCharacterImage;
  final VoidCallback onClearCharacterImage;

  const AvatarNameSection({
    super.key,
    required this.nameCtrl,
    required this.avatarCtrl,
    required this.refImageCtrl,
    required this.onPickCharacterImage,
    required this.onClearCharacterImage,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final screenWidth = MediaQuery.of(context).size.width;
    final imageWidth = screenWidth * 0.5;

    final helper = AvatarHelper(
      avatarUrl:
          avatarCtrl.text.trim().isEmpty ? null : avatarCtrl.text.trim(),
      characterImage:
          refImageCtrl.text.trim().isEmpty ? null : refImageCtrl.text.trim(),
      displayName: nameCtrl.text,
    );
    final hasCharacterImage = refImageCtrl.text.trim().isNotEmpty;

    return Column(
      children: [
        // 大立绘图（无边框，点击可上传）
        GestureDetector(
          onTap: onPickCharacterImage,
          child: SizedBox(
            width: imageWidth,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: MoeG2ClipRRect(
                radius: 16,
                child: helper.buildCharacterWidget(
                  fit: BoxFit.cover,
                  fallback: Container(
                    decoration: MoeG2Decoration(
                      radius: 16,
                      color: colors.surfaceAlt.withValues(alpha: 0.3),
                    ),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          color: colors.muted,
                          size: 40,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '点击上传立绘',
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 名称输入（居中）
        TextField(
          controller: nameCtrl,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: MoeFontWeights.emphasis,
            color: colors.text,
          ),
          decoration: InputDecoration(
            hintText: '输入角色名称',
            hintStyle: TextStyle(
              fontSize: 22,
              fontWeight: MoeFontWeights.normal,
              color: colors.muted,
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
        const SizedBox(height: 8),

        // 操作按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: onPickCharacterImage,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(hasCharacterImage ? '更换立绘' : '上传立绘'),
            ),
            if (hasCharacterImage) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onClearCharacterImage,
                icon: const Icon(Icons.close),
                label: const Text('清空立绘'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
