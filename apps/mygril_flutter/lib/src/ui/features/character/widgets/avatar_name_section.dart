/// AvatarNameSection - 角色编辑页：头像 + 名称行
///
/// 从 ContactEditPage 拆分，负责头像预览/选取 + 名称输入。
library;

import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../../../../core/utils/avatar_helper.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/theme/tokens.dart';

class AvatarNameSection extends StatelessWidget {
  final TextEditingController nameCtrl;
  final TextEditingController avatarCtrl;
  final TextEditingController refImageCtrl;
  final Uint8List? avatarBytes;
  final VoidCallback onPickAvatar;

  const AvatarNameSection({
    super.key,
    required this.nameCtrl,
    required this.avatarCtrl,
    required this.refImageCtrl,
    required this.avatarBytes,
    required this.onPickAvatar,
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

    return Row(
      children: [
        // 头像
        GestureDetector(
          onTap: onPickAvatar,
          child: Container(
            width: 72,
            height: 72,
            decoration: MoeG2Decoration(
              radius: radiusBubble.x,
              color: colors.surface,
              border: Border.all(color: colors.borderLight, width: 0.5),
            ),
            child: MoeG2ClipRRect(
              radius: radiusBubble.x,
              child: avatarBytes != null
                  ? Image.memory(avatarBytes!, fit: BoxFit.cover)
                  : helper.buildAvatarWidget(
                      fit: BoxFit.cover,
                      fallback: Center(
                        child: Icon(
                          Icons.add_a_photo_outlined,
                          color: colors.muted,
                          size: 28,
                        ),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        // 名称输入
        Expanded(
          child: TextField(
            controller: nameCtrl,
            style: TextStyle(
              fontSize: 20,
              fontWeight: MoeFontWeights.emphasis,
              color: colors.text,
            ),
            decoration: InputDecoration(
              hintText: '输入角色名称',
              hintStyle: TextStyle(
                fontSize: 20,
                fontWeight: MoeFontWeights.normal,
                color: colors.muted,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}
