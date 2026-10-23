import 'package:flutter/material.dart';

import '../../theme/moe_wallpaper.dart';
import 'moe_wallpaper_view.dart';

/// Default background shared by the workspace and conversations: the global
/// wallpaper when one is chosen, otherwise the plain scaffold color.
class MoeChatWallpaper extends StatelessWidget {
  const MoeChatWallpaper({
    super.key,
    required this.child,
    this.slot = GlobalWallpaperSlot.chat,
    this.style,
    this.layout,
  });
  final Widget child;
  final GlobalWallpaperSlot slot;

  /// See [MoeGlobalWallpaper.style].
  final WallpaperStyle? style;

  /// See [MoeWallpaperView.layout].
  final WallpaperLayout? layout;

  @override
  Widget build(BuildContext context) {
    return MoeGlobalWallpaper(
      slot: slot,
      color: Theme.of(context).scaffoldBackgroundColor,
      style: style,
      layout: layout,
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
    this.style,
    this.layout,
    this.child,
  });
  final GlobalWallpaperSlot slot;
  final Color color;

  /// Mask, blur and framing laid over the global image; null uses the global
  /// wallpaper's own. A character following the global image may adjust its own.
  final WallpaperStyle? style;

  /// See [MoeWallpaperView.layout].
  final WallpaperLayout? layout;
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
    final source = theme?.sourceFor(slot, Theme.of(context).brightness);
    if (theme == null || source == null) {
      return ColoredBox(color: color, child: child);
    }
    final wallpaper = MoeWallpaperView(
      source: source,
      style: style ?? theme.style,
      color: color,
      layout: layout,
      fallbackAlignment: theme.wallpaper.alignment,
    );
    return child == null
        ? wallpaper
        : Stack(fit: StackFit.expand, children: [wallpaper, child!]);
  }
}
