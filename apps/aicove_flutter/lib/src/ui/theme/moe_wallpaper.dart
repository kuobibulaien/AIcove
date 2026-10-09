import 'package:flutter/material.dart';

/// 全局壁纸：未自定义背景的界面统一使用的一组图。
/// 一组四张，按界面位置各取一张，浅色／深色各一版。
enum GlobalWallpaper {
  none('none', '无'),
  mist('mist', '雾蓝'),
  apricot('apricot', '暖杏');

  const GlobalWallpaper(this.value, this.label);
  final String value;
  final String label;

  String? assetFor(GlobalWallpaperSlot slot, Brightness brightness) {
    if (this == none) return null;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    return 'assets/wallpapers/${value}_${slot.index + 1}_$mode.webp';
  }

  static GlobalWallpaper fromValue(String? value) {
    for (final item in GlobalWallpaper.values) {
      if (item.value == value) return item;
    }
    return GlobalWallpaper.none;
  }
}

/// 全局壁纸在界面上的位置；同一组图按位置分配不同的一张。
enum GlobalWallpaperSlot { home, chat, page, empty }

/// 向界面层提供当前全局壁纸，共享组件不直接依赖设置状态。
class MoeWallpaperTheme extends InheritedWidget {
  const MoeWallpaperTheme({
    super.key,
    required this.wallpaper,
    required super.child,
  });

  final GlobalWallpaper wallpaper;

  static GlobalWallpaper of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MoeWallpaperTheme>()
          ?.wallpaper ??
      GlobalWallpaper.none;

  @override
  bool updateShouldNotify(MoeWallpaperTheme oldWidget) =>
      wallpaper != oldWidget.wallpaper;
}
