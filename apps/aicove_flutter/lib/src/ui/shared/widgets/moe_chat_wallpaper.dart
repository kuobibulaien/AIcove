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

  /// Whether a global wallpaper is active in this context.
  static bool isActive(BuildContext context) =>
      MoeWallpaperTheme.of(context) != GlobalWallpaper.none;

  @override
  Widget build(BuildContext context) {
    final asset = MoeWallpaperTheme.of(
      context,
    ).assetFor(slot, Theme.of(context).brightness);
    return ColoredBox(
      color: color,
      child: asset == null
          ? child
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.asset(
                  asset,
                  key: ValueKey(asset),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
                ?child,
              ],
            ),
    );
  }
}
