import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/data_image.dart';
import '../../theme/moe_wallpaper.dart';
import 'moe_static_blur_layer.dart';

/// 壁纸图片来源转图片源：data URI、网络、资源或本机文件；空串为 null。
ImageProvider? moeWallpaperImageProvider(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('data:image')) {
    final bytes = decodeDataImage(trimmed);
    return bytes == null ? null : MemoryImage(bytes);
  }
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return CachedNetworkImageProvider(trimmed);
  }
  if (trimmed.startsWith('assets/') || trimmed.startsWith('packages/')) {
    return AssetImage(trimmed);
  }
  return FileImage(File(trimmed));
}

/// 全局壁纸与角色壁纸共用的绘制：底色、按截取铺满的原图、静态模糊叠层与平铺遮罩。
/// 原图和模糊叠层共用同一截取，调节模糊不会错位。
class MoeWallpaperView extends StatefulWidget {
  const MoeWallpaperView({
    super.key,
    required this.source,
    required this.style,
    required this.color,
    this.layout,
    this.fallbackAlignment = Alignment.center,
  });

  /// 图片来源，见 [moeWallpaperImageProvider]。
  final String source;
  final WallpaperStyle style;

  /// 图片下的底色，也是遮罩的颜色。
  final Color color;

  /// 使用哪一形态的截取；为 null 时按当前窗口判断。
  final WallpaperLayout? layout;

  /// 两种形态都没调过截取时的焦点。
  final Alignment fallbackAlignment;

  @override
  State<MoeWallpaperView> createState() => _MoeWallpaperViewState();
}

class _MoeWallpaperViewState extends State<MoeWallpaperView> {
  // data URI 解码较重，按来源缓存，调节遮罩／模糊／截取时不重复解码。
  String? _source;
  ImageProvider? _provider;

  ImageProvider? _providerFor(String source) {
    if (_source != source) {
      _source = source;
      _provider = moeWallpaperImageProvider(source);
    }
    return _provider;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final provider = _providerFor(widget.source);
    if (provider == null) return ColoredBox(color: widget.color);
    final framing = style.framingFor(
      widget.layout ?? WallpaperLayout.of(context),
      fallback: widget.fallbackAlignment,
    );
    final alignment = framing.alignment;
    Widget picture = Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: provider,
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
        if (MoeStaticBlurLayer.opacityFor(style.blur) > 0)
          MoeStaticBlurLayer(
            key: const ValueKey('moe_wallpaper_blur'),
            source: widget.source,
            blur: style.blur,
            alignment: alignment,
          ),
      ],
    );
    if (framing.scale > 1) {
      picture = ClipRect(
        child: Transform.scale(
          scale: framing.scale,
          alignment: alignment,
          child: picture,
        ),
      );
    }
    final mask = style.mask.clamp(0.0, 1.0);
    return ColoredBox(
      color: widget.color,
      child: Stack(
        fit: StackFit.expand,
        children: [
          picture,
          if (mask > 0)
            IgnorePointer(
              child: ColoredBox(color: widget.color.withValues(alpha: mask)),
            ),
        ],
      ),
    );
  }
}

/// 读取 [provider] 的原图尺寸，供截取拖动换算；读不到时为 null。
Future<Size?> resolveWallpaperImageSize(
  ImageProvider provider,
  ImageConfiguration configuration,
) {
  final completer = Completer<Size?>();
  final stream = provider.resolve(configuration);
  late final ImageStreamListener listener;
  void finish(Size? size) {
    if (!completer.isCompleted) completer.complete(size);
    stream.removeListener(listener);
  }

  listener = ImageStreamListener(
    (info, _) =>
        finish(Size(info.image.width.toDouble(), info.image.height.toDouble())),
    onError: (_, __) => finish(null),
  );
  stream.addListener(listener);
  return completer.future;
}
