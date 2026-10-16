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
          fallback: _BlurredColorFallback(color: context.moeColors.primary),
        ),
      ),
    );
  }
}

/// Soft, blurred-looking color disc derived from the accent color.
/// Built from radial gradients so lists pay no blur-filter cost.
class _BlurredColorFallback extends StatelessWidget {
  const _BlurredColorFallback({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    var hsl = HSLColor.fromColor(color);
    if (dark) hsl = hsl.withSaturation(hsl.saturation * 0.45);
    Color shifted(double hue, double lightness) => hsl
        .withHue((hsl.hue + hue) % 360)
        .withLightness(lightness.clamp(0.0, 1.0))
        .toColor();
    final base = shifted(0, dark ? 0.30 : 0.86);
    final warm = shifted(-28, dark ? 0.40 : 0.78);
    final cool = shifted(36, dark ? 0.38 : 0.80);

    return DecoratedBox(
      decoration: BoxDecoration(color: base),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.55, -0.6),
                radius: 0.9,
                colors: [warm, warm.withValues(alpha: 0)],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.6, 0.65),
                radius: 0.85,
                colors: [cool, cool.withValues(alpha: 0)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
