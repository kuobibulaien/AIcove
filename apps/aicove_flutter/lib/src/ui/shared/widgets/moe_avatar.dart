import 'package:flutter/material.dart';

import '../../../core/utils/avatar_helper.dart';
import '../../theme/tokens.dart';

class MoeAvatar extends StatelessWidget {
  const MoeAvatar(
      {super.key,
      required this.name,
      this.avatarUrl,
      this.characterImage,
      this.size = 56});
  final String name;
  final String? avatarUrl;
  final String? characterImage;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: AvatarHelper(
                avatarUrl: avatarUrl,
                characterImage: characterImage,
                displayName: name)
            .buildAvatarWidget(
          // Placeholder must stand out from both the page and card colors.
          fallback: ColoredBox(
            color: context.moeColors.border,
            child: Icon(
              Icons.person_rounded,
              size: size * 0.6,
              color: context.moeColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
