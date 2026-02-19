/// Composer 更多面板
///
/// 显示模型选择、相册、拍照、文件等操作入口
library;

import 'package:flutter/material.dart';
import '../../../../ui/theme/tokens.dart';

/// 更多面板操作类型
enum ComposerAction { model, gallery, camera, file }

/// Composer 更多面板
class ComposerMorePanel extends StatelessWidget {
  final ValueChanged<ComposerAction> onAction;

  const ComposerMorePanel({super.key, required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      child: GridView.count(
        crossAxisCount: 4,
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          MoreActionTile(
            icon: Icons.tune,
            label: '模型',
            onTap: () => onAction(ComposerAction.model),
          ),
          MoreActionTile(
            icon: Icons.photo_library_outlined,
            label: '相册',
            onTap: () => onAction(ComposerAction.gallery),
          ),
          MoreActionTile(
            icon: Icons.photo_camera_outlined,
            label: '拍照',
            onTap: () => onAction(ComposerAction.camera),
          ),
          MoreActionTile(
            icon: Icons.attach_file,
            label: '文件',
            onTap: () => onAction(ComposerAction.file),
          ),
        ],
      ),
    );
  }
}

/// 更多面板操作按钮
class MoreActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const MoreActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 26, color: colors.text),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.text,
                  fontWeight: MoeFontWeights.emphasis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
