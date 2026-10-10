import 'package:flutter/material.dart';

import '../../theme/moe_wallpaper.dart';

/// Default background shared by the workspace and conversations: the global
/// wallpaper when one is chosen, otherwise the plain scaffold color.
class MoeChatWallpaper extends StatelessWidget {
  const MoeChatWallpaper({
    super.key,
    required this.child,
    this.slot = GlobalWallpaperSlot.chat,
  });
  final Widget child;
  final GlobalWallpaperSlot slot;

  @override
  Widget build(BuildContext context) {
    return MoeGlobalWallpaper(
      slot: slot,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox.expand(child: child),
    );
  }
}

/// Paints [color], covered by the global wallpaper image for [slot] if set.
class MoeGlobalWallpaper extends StatelessWidget {
  const MoeGlobalWallpaper({
    super.key,
    required this.slot,
    required this.color,
    this.child,
  });
  final GlobalWallpaperSlot slot;
  final Color color;
  final Widget? child;

  /// Whether a global wallpaper image is active in this context.
  static bool isActive(BuildContext context) =>
      MoeWallpaperTheme.maybeOf(
        context,
      )?.imageFor(GlobalWallpaperSlot.page, Brightness.light) !=
      null;

  @override
  Widget build(BuildContext context) {
    final theme = MoeWallpaperTheme.maybeOf(context);
    final image = theme?.imageFor(slot, Theme.of(context).brightness);
    final mask = theme?.maskOpacity ?? 0;
    return ColoredBox(
      color: color,
      child: image == null
          ? child
          : Stack(
              fit: StackFit.expand,
              children: [
                Image(
                  image: image,
                  key: ValueKey(image),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
                if (mask > 0) ColoredBox(color: color.withValues(alpha: mask)),
                ?child,
              ],
            ),
    );
  }
}
