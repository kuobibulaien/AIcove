import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'tokens.dart' show layoutBreakpoint;

/// 全局壁纸：未自定义背景的界面统一使用的一张图，浅色／深色各一版。
enum GlobalWallpaper {
  none('none', '无'),
  catnap('catnap', '猫窗'),
  laketown('laketown', '灯湖'),
  custom('custom', '自定义');

  const GlobalWallpaper(this.value, this.label);
  final String value;
  final String label;

  String? assetFor(GlobalWallpaperSlot slot, Brightness brightness) {
    if (this == none || this == custom) return null;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    return 'assets/wallpapers/${value}_$mode.webp';
  }

  /// 未调过截取位置时的默认焦点：竖屏裁切保留画面左侧的猫咪与植物。
  Alignment get alignment =>
      this == catnap ? Alignment.centerLeft : Alignment.center;

  static GlobalWallpaper fromValue(String? value) {
    // 旧内置壁纸（mist／apricot）已移除，选过的改用当前内置壁纸。
    if (value == 'mist' || value == 'apricot') return catnap;
    for (final item in GlobalWallpaper.values) {
      if (item.value == value) return item;
    }
    return GlobalWallpaper.none;
  }
}

/// 全局壁纸在界面上的位置；目前内置壁纸各位置共用同一张。
enum GlobalWallpaperSlot { home, chat, page, empty }

/// 自定义壁纸默认遮罩：用页面底色盖住照片，保证文字可读。
const double kDefaultCustomWallpaperMask = 0.35;

/// 壁纸模糊的上限，与聊天背景的模糊滑块一致。
const double kMaxWallpaperBlur = 30;

/// 用户添加的一张自定义壁纸，图片存在本机。
@immutable
class CustomWallpaper {
  const CustomWallpaper({required this.id, required this.imagePath});

  final String id;
  final String imagePath;

  Map<String, dynamic> toJson() => {'id': id, 'path': imagePath};

  static CustomWallpaper? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] as String?)?.trim() ?? '';
    final path = (raw['path'] as String?)?.trim() ?? '';
    if (id.isEmpty || path.isEmpty) return null;
    return CustomWallpaper(id: id, imagePath: path);
  }

  @override
  bool operator ==(Object other) =>
      other is CustomWallpaper &&
      other.id == id &&
      other.imagePath == imagePath;

  @override
  int get hashCode => Object.hash(id, imagePath);
}

/// 截取的最大放大倍数。
const double kMaxWallpaperScale = 4;

/// 壁纸所在界面的形态。宽窄各自可以有一份截取位置，没单独调过的沿用另一份。
enum WallpaperLayout {
  narrow('窄屏'),
  wide('宽屏');

  const WallpaperLayout(this.label);
  final String label;

  WallpaperLayout get other => this == narrow ? wide : narrow;

  /// 当前窗口的形态，与工作区的宽屏断点一致。
  static WallpaperLayout of(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= layoutBreakpoint ? wide : narrow;
}

/// 壁纸的截取：铺满（cover）后以焦点 [x]、[y]（-1..1，同 [Alignment]）为中心
/// 再放大 [scale] 倍；焦点在画面里的相对位置保持不变，所以任何比例都不会露边。
@immutable
class WallpaperFraming {
  const WallpaperFraming({this.x = 0, this.y = 0, this.scale = 1});

  WallpaperFraming.fromAlignment(Alignment alignment)
    : x = alignment.x,
      y = alignment.y,
      scale = 1;

  final double x;
  final double y;
  final double scale;

  Alignment get alignment => Alignment(x, y);

  WallpaperFraming copyWith({double? x, double? y, double? scale}) =>
      WallpaperFraming(
        x: (x ?? this.x).clamp(-1.0, 1.0).toDouble(),
        y: (y ?? this.y).clamp(-1.0, 1.0).toDouble(),
        scale: (scale ?? this.scale).clamp(1.0, kMaxWallpaperScale).toDouble(),
      );

  /// 在显示区 [box] 里按屏幕像素拖动 [delta]，图片跟手移动。
  /// [image] 是原图尺寸；某一方向没有可移动余量时该方向不动。
  WallpaperFraming dragged(Offset delta, {required Size box, required Size image}) {
    if (box.isEmpty || image.isEmpty) return this;
    final cover = [box.width / image.width, box.height / image.height]
        .reduce((a, b) => a > b ? a : b);
    double moved(double value, double d, double boxLength, double imageLength) {
      final overflow = imageLength * cover * scale - boxLength;
      if (overflow < 0.5) return value;
      return value - 2 * d / overflow;
    }

    return copyWith(
      x: moved(x, delta.dx, box.width, image.width),
      y: moved(y, delta.dy, box.height, image.height),
    );
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'scale': scale};

  static WallpaperFraming? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double read(String key, double fallback) =>
        (raw[key] as num?)?.toDouble() ?? fallback;
    return const WallpaperFraming().copyWith(
      x: read('x', 0),
      y: read('y', 0),
      scale: read('scale', 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperFraming &&
      other.x == x &&
      other.y == y &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(x, y, scale);
}

/// 一张壁纸的调节：底色遮罩（0..1）、模糊（0..[kMaxWallpaperBlur]）与宽窄屏截取。
/// 全局壁纸和角色专属壁纸共用这一套。
@immutable
class WallpaperStyle {
  const WallpaperStyle({this.mask = 0, this.blur = 0, this.narrow, this.wide});

  /// 未调节过的默认值：内置图本身已足够素淡不加遮罩，自定义照片默认盖一层。
  const WallpaperStyle.defaultFor({required bool custom})
    : mask = custom ? kDefaultCustomWallpaperMask : 0,
      blur = 0,
      narrow = null,
      wide = null;

  final double mask;
  final double blur;

  /// 窄屏／宽屏各自的截取；为 null 时沿用另一形态的，两者都没有时用默认焦点。
  final WallpaperFraming? narrow;
  final WallpaperFraming? wide;

  WallpaperFraming? ownFraming(WallpaperLayout layout) =>
      layout == WallpaperLayout.narrow ? narrow : wide;

  /// [layout] 下实际使用的截取。
  WallpaperFraming framingFor(
    WallpaperLayout layout, {
    Alignment fallback = Alignment.center,
  }) =>
      ownFraming(layout) ??
      ownFraming(layout.other) ??
      WallpaperFraming.fromAlignment(fallback);

  /// 设置（或以 null 清除）[layout] 自己的截取。
  WallpaperStyle withFraming(WallpaperLayout layout, WallpaperFraming? framing) =>
      WallpaperStyle(
        mask: mask,
        blur: blur,
        narrow: layout == WallpaperLayout.narrow ? framing : narrow,
        wide: layout == WallpaperLayout.wide ? framing : wide,
      );

  WallpaperStyle copyWith({double? mask, double? blur}) => WallpaperStyle(
    mask: mask ?? this.mask,
    blur: blur ?? this.blur,
    narrow: narrow,
    wide: wide,
  );

  Map<String, dynamic> toJson() => {
    'mask': mask,
    'blur': blur,
    ...framingJson,
  };

  /// 只含截取的部分；角色壁纸把它单独存一列。
  Map<String, dynamic> get framingJson => {
    if (narrow != null) 'narrow': narrow!.toJson(),
    if (wide != null) 'wide': wide!.toJson(),
  };

  /// [framingJson] 编码后的文本，没有截取时为 null。
  String? get encodedFraming =>
      framingJson.isEmpty ? null : jsonEncode(framingJson);

  /// 换上 [encoded]（[encodedFraming] 的结果）里的截取。
  WallpaperStyle withEncodedFraming(String? encoded) {
    Object? raw;
    try {
      raw = encoded == null || encoded.isEmpty ? null : jsonDecode(encoded);
    } on FormatException {
      raw = null;
    }
    final map = raw is Map ? raw : const {};
    return WallpaperStyle(
      mask: mask,
      blur: blur,
      narrow: WallpaperFraming.fromJson(map['narrow']),
      wide: WallpaperFraming.fromJson(map['wide']),
    );
  }

  static WallpaperStyle fromJson(Object? raw, {required bool custom}) {
    final fallback = WallpaperStyle.defaultFor(custom: custom);
    if (raw is! Map) return fallback;
    return WallpaperStyle(
      mask: ((raw['mask'] as num?)?.toDouble() ?? fallback.mask)
          .clamp(0.0, 1.0)
          .toDouble(),
      blur: ((raw['blur'] as num?)?.toDouble() ?? fallback.blur)
          .clamp(0.0, kMaxWallpaperBlur)
          .toDouble(),
      narrow: WallpaperFraming.fromJson(raw['narrow']),
      wide: WallpaperFraming.fromJson(raw['wide']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperStyle &&
      other.mask == mask &&
      other.blur == blur &&
      other.narrow == narrow &&
      other.wide == wide;

  @override
  int get hashCode => Object.hash(mask, blur, narrow, wide);
}

/// 向界面层提供当前全局壁纸，共享组件不直接依赖设置状态。
class MoeWallpaperTheme extends InheritedWidget {
  const MoeWallpaperTheme({
    super.key,
    required this.wallpaper,
    this.customImagePath,
    this.style = const WallpaperStyle(),
    required super.child,
  });

  final GlobalWallpaper wallpaper;

  /// 当前自定义壁纸在本机的图片文件路径。
  final String? customImagePath;

  /// 当前壁纸的遮罩与模糊。
  final WallpaperStyle style;

  static MoeWallpaperTheme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeWallpaperTheme>();

  static GlobalWallpaper of(BuildContext context) =>
      maybeOf(context)?.wallpaper ?? GlobalWallpaper.none;

  /// 当前位置壁纸图的来源（资源名或本机路径）；未选或自定义图缺失时为 null。
  String? sourceFor(GlobalWallpaperSlot slot, Brightness brightness) {
    if (wallpaper == GlobalWallpaper.custom) {
      final path = customImagePath?.trim();
      return path == null || path.isEmpty ? null : path;
    }
    return wallpaper.assetFor(slot, brightness);
  }

  /// 当前位置应铺的壁纸图；未选或自定义图缺失时为 null。
  ImageProvider? imageFor(GlobalWallpaperSlot slot, Brightness brightness) {
    final source = sourceFor(slot, brightness);
    if (source == null) return null;
    return wallpaper == GlobalWallpaper.custom
        ? FileImage(File(source))
        : AssetImage(source);
  }

  /// 图片上覆盖的底色不透明度。
  double get maskOpacity => style.mask.clamp(0.0, 1.0).toDouble();

  /// 图片模糊程度（0..[kMaxWallpaperBlur]）。
  double get blur => style.blur.clamp(0.0, kMaxWallpaperBlur).toDouble();

  @override
  bool updateShouldNotify(MoeWallpaperTheme oldWidget) =>
      wallpaper != oldWidget.wallpaper ||
      customImagePath != oldWidget.customImagePath ||
      style != oldWidget.style;
}
