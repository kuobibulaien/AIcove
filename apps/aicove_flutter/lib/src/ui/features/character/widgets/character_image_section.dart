/// CharacterImageSection - 角色编辑页：角色立绘区
///
/// 从 ContactEditPage 拆分，负责立绘预览 + 上传/清空操作。
library;

import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/effects/frosted_glass_card.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';
import 'edit_section_title.dart';

class CharacterImageSection extends StatelessWidget {
  final TextEditingController avatarCtrl;
  final TextEditingController refImageCtrl;
  final TextEditingController nameCtrl;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const CharacterImageSection({
    super.key,
    required this.avatarCtrl,
    required this.refImageCtrl,
    required this.nameCtrl,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final helper = AvatarHelper(
      avatarUrl:
          avatarCtrl.text.trim().isEmpty ? null : avatarCtrl.text.trim(),
      characterImage:
          refImageCtrl.text.trim().isEmpty ? null : refImageCtrl.text.trim(),
      displayName: nameCtrl.text,
    );
    final hasCharacterImage = refImageCtrl.text.trim().isNotEmpty;

    return FrostedGlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EditSectionTitle(
            icon: Icons.portrait_outlined,
            title: '角色立绘',
            subtitle: '立绘用于角色卡和详情展示，不等同于头像',
          ),
          const SizedBox(height: 8),
          MoeG2ClipRRect(
            radius: 12,
            child: Container(
              width: double.infinity,
              height: 180,
              decoration: MoeG2Decoration(
                radius: 12,
                color: colors.surfaceAlt.withValues(alpha: 0.25),
                border: Border.all(color: colors.borderLight, width: 0.5),
              ),
              child: Center(
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: MoeG2ClipRRect(
                    radius: 10,
                    child: helper.buildCharacterWidget(
                      fit: BoxFit.cover,
                      fallback: Container(
                        color: colors.surface,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.image_outlined,
                          color: colors.muted,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(hasCharacterImage ? '更换立绘' : '上传立绘'),
                ),
              ),
              if (hasCharacterImage) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.close),
                    label: const Text('清空立绘'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
