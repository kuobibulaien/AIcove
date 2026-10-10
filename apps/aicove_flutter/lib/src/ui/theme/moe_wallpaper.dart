import 'dart:io';

import 'package:flutter/material.dart';

/// 全局壁纸：未自定义背景的界面统一使用的一组图。
/// 一组四张，按界面位置各取一张，浅色／深色各一版。
enum GlobalWallpaper {
  none('none', '无'),
  mist('mist', '雾蓝'),
  apricot('apricot', '暖杏'),
  custom('custom', '自定义');

  const GlobalWallpaper(this.value, this.label);
  final String value;
  final String label;

  String? assetFor(GlobalWallpaperSlot slot, Brightness brightness) {
    if (this == none || this == custom) return null;
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

/// 自定义壁纸默认遮罩：用页面底色盖住照片，保证文字可读。
const double kDefaultCustomWallpaperMask = 0.35;

/// 向界面层提供当前全局壁纸，共享组件不直接依赖设置状态。
class MoeWallpaperTheme extends InheritedWidget {
  const MoeWallpaperTheme({
    super.key,
    required this.wallpaper,
    this.customImagePath,
    this.customMask = kDefaultCustomWallpaperMask,
    required super.child,
  });

  final GlobalWallpaper wallpaper;

  /// 自定义壁纸在本机的图片文件路径。
  final String? customImagePath;

  /// 自定义壁纸上覆盖的页面底色不透明度（0..1）。
  final double customMask;

  static MoeWallpaperTheme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeWallpaperTheme>();

  static GlobalWallpaper of(BuildContext context) =>
      maybeOf(context)?.wallpaper ?? GlobalWallpaper.none;

  /// 当前位置应铺的壁纸图；未选或自定义图缺失时为 null。
  ImageProvider? imageFor(GlobalWallpaperSlot slot, Brightness brightness) {
    if (wallpaper == GlobalWallpaper.custom) {
      final path = customImagePath?.trim();
      return path == null || path.isEmpty ? null : FileImage(File(path));
    }
    final asset = wallpaper.assetFor(slot, brightness);
    return asset == null ? null : AssetImage(asset);
  }

  /// 图片上覆盖的底色不透明度；内置图本身已足够素淡，不加遮罩。
  double get maskOpacity => wallpaper == GlobalWallpaper.custom
      ? customMask.clamp(0.0, 1.0).toDouble()
      : 0;

  @override
  bool updateShouldNotify(MoeWallpaperTheme oldWidget) =>
      wallpaper != oldWidget.wallpaper ||
      customImagePath != oldWidget.customImagePath ||
      customMask != oldWidget.customMask;
}
