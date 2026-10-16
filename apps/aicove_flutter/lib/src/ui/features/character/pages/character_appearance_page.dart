/// CharacterAppearancePage - 角色编辑页「自定义」：立绘与头像
///
/// 上方并排预览立绘与头像，下方是更换立绘、从立绘裁剪头像、上传头像，
/// 以及进入聊天壁纸编辑页的入口。数据由角色编辑页持有，本页只展示并回调。
library;

import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/index.dart';
import '../../../../ui/theme/tokens.dart';

class CharacterAppearancePage extends StatelessWidget {
  const CharacterAppearancePage({
    super.key,
    required this.nameCtrl,
    required this.avatarCtrl,
    required this.refImageCtrl,
    required this.onPickCharacterImage,
    required this.onCropAvatarFromCharacter,
    required this.onPickAvatar,
    required this.onEditWallpaper,
  });

  final TextEditingController nameCtrl;
  final TextEditingController avatarCtrl;
  final TextEditingController refImageCtrl;
  final VoidCallback onPickCharacterImage;
  final VoidCallback onCropAvatarFromCharacter;
  final VoidCallback onPickAvatar;
  final VoidCallback onEditWallpaper;

  @override
  Widget build(BuildContext context) {
    return MoePageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const MoeAppBar(title: '自定义形象', showBackButton: true),
      body: ListenableBuilder(
        listenable: Listenable.merge([avatarCtrl, refImageCtrl]),
        builder: (context, _) => _buildContent(context),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.moeColors;
    final avatar = avatarCtrl.text.trim();
    final character = refImageCtrl.text.trim();
    final hasCharacter = character.isNotEmpty;
    final characterHelper = AvatarHelper(
      characterImage: hasCharacter ? character : null,
      displayName: nameCtrl.text,
    );
    final avatarHelper = AvatarHelper(
      avatarUrl: avatar.isEmpty ? null : avatar,
      characterImage: hasCharacter ? character : null,
      displayName: nameCtrl.text,
    );

    return SingleChildScrollView(
      padding: moeUnderBarPadding(context),
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Preview(
                  label: '立绘',
                  onTap: onPickCharacterImage,
                  child: SizedBox(
                    width: 150,
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: MoeG2ClipRRect(
                        radius: 16,
                        child: characterHelper.buildCharacterWidget(
                          fit: BoxFit.cover,
                          fallback: _placeholder(colors, 16),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                _Preview(
                  label: '头像',
                  onTap: onPickAvatar,
                  child: ClipOval(
                    child: SizedBox.square(
                      dimension: 88,
                      child: avatarHelper.buildAvatarWidget(
                        fit: BoxFit.cover,
                        fallback: _placeholder(colors, 44),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            MoeSettingsGroup(
              margin: EdgeInsets.zero,
              children: [
                MoeSettingsRow(
                  icon: Icons.photo_library_outlined,
                  label: hasCharacter ? '更换立绘' : '上传立绘',
                  subtitle: '换立绘后会接着裁剪头像',
                  onTap: onPickCharacterImage,
                ),
                if (hasCharacter)
                  MoeSettingsRow(
                    icon: Icons.crop,
                    label: '从立绘裁剪头像',
                    onTap: onCropAvatarFromCharacter,
                  ),
                MoeSettingsRow(
                  icon: Icons.account_circle_outlined,
                  label: '上传头像',
                  showDivider: false,
                  onTap: onPickAvatar,
                ),
              ],
            ),
            const SizedBox(height: 16),
            MoeSettingsGroup(
              margin: EdgeInsets.zero,
              children: [
                MoeSettingsRow(
                  icon: Icons.wallpaper_outlined,
                  label: '聊天壁纸',
                  showDivider: false,
                  onTap: onEditWallpaper,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(MoeColors colors, double radius) {
    return Container(
      decoration: MoeG2Decoration(
        radius: radius,
        color: colors.surfaceAlt.withValues(alpha: 0.5),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.add_photo_alternate_outlined, color: colors.muted),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 8),
          Text(label, style: TextStyle(fontSize: 13, color: colors.muted)),
        ],
      ),
    );
  }
}
