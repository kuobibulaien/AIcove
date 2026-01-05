/// 消息输入框功能菜单组件
/// 
/// 从 composer.dart 提取，显示照片、拍照、模型选择等功能入口。
/// 
/// 更新记录：
/// - 2025-12-31: 从 composer.dart 提取
library;

import 'package:flutter/material.dart';
import '../../../../../ui/theme/tokens.dart';

/// 功能菜单内容
class ComposerActionsMenu extends StatelessWidget {
  final VoidCallback onSelectModel;
  final VoidCallback onPickImage;
  final VoidCallback onTakePhoto;
  final ValueChanged<String> onActionTap;

  const ComposerActionsMenu({
    super.key,
    required this.onSelectModel,
    required this.onPickImage,
    required this.onTakePhoto,
    required this.onActionTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          ComposerActionButton(
            icon: Icons.smart_toy_outlined,
            label: '选择模型',
            onTap: onSelectModel,
          ),
          ComposerActionButton(
            icon: Icons.image_outlined,
            label: '照片',
            onTap: onPickImage,
          ),
          ComposerActionButton(
            icon: Icons.camera_alt_outlined,
            label: '拍照',
            onTap: onTakePhoto,
          ),
          ComposerActionButton(
            icon: Icons.phone_outlined,
            label: '语音通话',
            onTap: () => onActionTap('语音通话'),
          ),
          ComposerActionButton(
            icon: Icons.videocam_outlined,
            label: '视频通话',
            onTap: () => onActionTap('视频通话'),
          ),
          ComposerActionButton(
            icon: Icons.shuffle_outlined,
            label: '戳一戳',
            onTap: () => onActionTap('戳一戳'),
          ),
          ComposerActionButton(
            icon: Icons.card_giftcard_outlined,
            label: '红包',
            onTap: () => onActionTap('红包'),
          ),
          ComposerActionButton(
            icon: Icons.location_on_outlined,
            label: '位置',
            onTap: () => onActionTap('位置'),
          ),
          ComposerActionButton(
            icon: Icons.folder_outlined,
            label: '文件',
            onTap: () => onActionTap('文件'),
          ),
        ],
      ),
    );
  }
}

/// 功能按钮组件
class ComposerActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const ComposerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tileBgColor = isDark ? colors.panel : Colors.white;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: tileBgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: Icon(icon, size: 26, color: colors.muted),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: colors.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
