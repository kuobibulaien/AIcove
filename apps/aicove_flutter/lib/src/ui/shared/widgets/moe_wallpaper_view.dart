import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/utils/data_image.dart';
import '../../theme/moe_wallpaper.dart';

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

/// 全局壁纸与角色壁纸共用的绘制：底色、按截取铺满的原图、高斯模糊滤镜与平铺遮罩。
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

class _WallpaperBakeSpec {
  _WallpaperBakeSpec({
    required this.source,
    required this.sigma,
    required this.alignment,
    required this.scale,
    required this.width,
    required this.height,
    required this.dpr,
  }) : _sigmaKey = (sigma * 20).round(),
       _alignXKey = (alignment.x * 1000).round(),
       _alignYKey = (alignment.y * 1000).round(),
       _scaleKey = (scale * 1000).round(),
       _dprKey = (dpr * 100).round();

  final String source;
  final double sigma;
  final Alignment alignment;
  final double scale;
  final int width;
  final int height;
  final double dpr;

  final int _sigmaKey;
  final int _alignXKey;
  final int _alignYKey;
  final int _scaleKey;
  final int _dprKey;

  @override
  bool operator ==(Object other) =>
      other is _WallpaperBakeSpec &&
      other.source == source &&
      other._sigmaKey == _sigmaKey &&
      other._alignXKey == _alignXKey &&
      other._alignYKey == _alignYKey &&
      other._scaleKey == _scaleKey &&
      other.width == width &&
      other.height == height &&
      other._dprKey == _dprKey;

  @override
  int get hashCode => Object.hash(
    source,
    _sigmaKey,
    _alignXKey,
    _alignYKey,
    _scaleKey,
    width,
    height,
    _dprKey,
  );
}

/// Bounded cross-route LRU cache of pre-baked blurred wallpapers so route
/// pushes and pops render the static texture on Frame 1 instead of falling
/// back to a full-screen live [ImageFiltered] blur.
abstract final class _WallpaperBakeCache {
  static const int _maxEntries = 4;
  static final _entries = <_WallpaperBakeSpec, ui.Image>{};

  static ui.Image? acquire(_WallpaperBakeSpec spec) {
    final existing = _entries.remove(spec);
    if (existing == null) return null;
    _entries[spec] = existing;
    return existing.clone();
  }

  static void put(_WallpaperBakeSpec spec, ui.Image image) {
    _entries.remove(spec)?.dispose();
    _entries[spec] = image.clone();
    while (_entries.length > _maxEntries) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey)?.dispose();
    }
  }
}

class _MoeWallpaperViewState extends State<MoeWallpaperView> {
  // data URI 解码较重，按来源缓存，调节遮罩／模糊／截取时不重复解码。
  String? _source;
  ImageProvider? _provider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ui.Image? _resolvedRawImage;
  _WallpaperBakeSpec? _desiredSpec;
  _WallpaperBakeSpec? _bakedSpec;
  ui.Image? _bakedImage;
  bool _baking = false;

  static final bool _isFlutterTest =
      Platform.environment.containsKey('FLUTTER_TEST');

  ImageProvider? _providerFor(String source) {
    if (_source != source) {
      _source = source;
      _provider = moeWallpaperImageProvider(source);
      _unsubscribeImageStream();
      _resolvedRawImage = null;
      _clearBakedImage();
    }
    return _provider;
  }

  void _unsubscribeImageStream() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    _imageStream = null;
    _imageListener = null;
  }

  void _clearBakedImage() {
    _bakedImage?.dispose();
    _bakedImage = null;
    _bakedSpec = null;
  }

  void _ensureImageStream(ImageProvider provider, BuildContext context) {
    if (_isFlutterTest) return;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _imageStream?.key) return;
    _unsubscribeImageStream();
    _imageStream = stream;
    _imageListener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        _resolvedRawImage = info.image;
        _triggerBakeIfNeeded();
      },
      onError: (_, __) {},
    );
    stream.addListener(_imageListener!);
  }

  void _requestBake(_WallpaperBakeSpec spec) {
    if (_isFlutterTest) return;
    _desiredSpec = spec;
    if (_bakedSpec == spec && _bakedImage != null) return;
    final cached = _WallpaperBakeCache.acquire(spec);
    if (cached != null) {
      _bakedImage?.dispose();
      _bakedImage = cached;
      _bakedSpec = spec;
      return;
    }
    _triggerBakeIfNeeded();
  }

  Future<void> _triggerBakeIfNeeded() async {
    if (_baking || !mounted) return;
    final spec = _desiredSpec;
    final raw = _resolvedRawImage;
    if (spec == null || raw == null || _bakedSpec == spec) return;
    if (spec.width <= 0 || spec.height <= 0) return;

    _baking = true;
    try {
      while (mounted && _desiredSpec != null && _resolvedRawImage != null) {
        final currentSpec = _desiredSpec!;
        final currentRaw = _resolvedRawImage!;
        if (_bakedSpec == currentSpec && _bakedImage != null) break;

        final cached = _WallpaperBakeCache.acquire(currentSpec);
        if (cached != null) {
          setState(() {
            _bakedImage?.dispose();
            _bakedImage = cached;
            _bakedSpec = currentSpec;
          });
          break;
        }

        final downscale = currentSpec.sigma >= 12.0
            ? 0.25
            : currentSpec.sigma >= 4.0
            ? 0.5
            : 1.0;
        final effScale = (currentSpec.dpr * downscale).clamp(0.25, 3.0);
        final targetW = (currentSpec.width * effScale).round().clamp(1, 2048);
        final targetH = (currentSpec.height * effScale).round().clamp(1, 2048);
        final rect = Offset.zero & Size(targetW.toDouble(), targetH.toDouble());
        final scaledSigma = currentSpec.sigma * effScale;

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, rect);
        canvas.clipRect(rect);
        canvas.saveLayer(
          rect,
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: scaledSigma,
              sigmaY: scaledSigma,
              tileMode: TileMode.clamp,
            ),
        );
        if (currentSpec.scale > 1) {
          final pivot = currentSpec.alignment.withinRect(rect);
          canvas.translate(pivot.dx, pivot.dy);
          canvas.scale(currentSpec.scale, currentSpec.scale);
          canvas.translate(-pivot.dx, -pivot.dy);
        }
        paintImage(
          canvas: canvas,
          rect: rect,
          image: currentRaw,
          fit: BoxFit.cover,
          alignment: currentSpec.alignment,
          filterQuality: FilterQuality.medium,
        );
        canvas.restore();

        final picture = recorder.endRecording();
        final image = await picture.toImage(targetW, targetH);
        picture.dispose();
        _WallpaperBakeCache.put(currentSpec, image);

        if (!mounted) {
          image.dispose();
          return;
        }
        if (_desiredSpec == currentSpec) {
          setState(() {
            _bakedImage?.dispose();
            _bakedImage = image;
            _bakedSpec = currentSpec;
          });
          break;
        } else {
          image.dispose();
        }
      }
    } catch (_) {
      // 预烘焙失败时保持实时 ImageFiltered 回退。
    } finally {
      _baking = false;
    }
  }

  @override
  void dispose() {
    _unsubscribeImageStream();
    _clearBakedImage();
    super.dispose();
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
    final sigma = style.blur.clamp(0.0, kMaxWallpaperBlur).toDouble();
    if (sigma > 0.1) {
      _ensureImageStream(provider, context);
    } else if (_bakedImage != null) {
      _clearBakedImage();
    }

    Widget buildLivePicture() {
      Widget picture = SizedBox.expand(
        child: Image(
          image: provider,
          fit: BoxFit.cover,
          alignment: alignment,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
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
      return picture;
    }

    Widget picture;
    if (sigma > 0.1) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
      picture = LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth.isFinite
              ? constraints.maxWidth.round()
              : 0;
          final h = constraints.maxHeight.isFinite
              ? constraints.maxHeight.round()
              : 0;
          final spec = _WallpaperBakeSpec(
            source: widget.source,
            sigma: sigma,
            alignment: alignment,
            scale: framing.scale,
            width: w,
            height: h,
            dpr: dpr,
          );
          _requestBake(spec);
          final hasBaked = _bakedSpec == spec && _bakedImage != null;
          return ClipRect(
            child: ImageFiltered(
              key: const ValueKey('moe_wallpaper_blur'),
              enabled: !hasBaked,
              imageFilter: ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
              child: hasBaked
                  ? SizedBox.expand(
                      child: RawImage(
                        image: _bakedImage,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                      ),
                    )
                  : buildLivePicture(),
            ),
          );
        },
      );
    } else {
      picture = buildLivePicture();
    }
    final mask = style.mask.clamp(0.0, 1.0);
    return RepaintBoundary(
      child: ColoredBox(
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
