import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// 静态模糊背景缓存
///
/// 将海报图预先模糊处理并缓存，避免实时全屏高斯模糊的性能开销。
/// 支持预热、LRU 缓存、首次 fallback（低分辨率放大版）。

class BlurredBackgroundCache {
  BlurredBackgroundCache._();

  /// LRU 缓存容量
  static const int _maxCacheSize = 12;

  /// 静态模糊强度：更接近 iOS 毛玻璃的“深模糊”观感
  static const double _blurSigma = 40;

  /// 首次兜底：低清放大宽度（用户确认使用 64）
  static const int _fallbackResizeWidth = 64;

  /// 生成静态模糊图时的目标短边尺寸。
  /// 说明：如果尺寸太小，再叠加 sigma=25 会“糊成一片”；提高分辨率能保留毛玻璃的质感纹理。
  static const int _targetShortSide = 720;

  /// 静态模糊图最大边（避免生成图过大导致内存压力）
  static const int _maxSide = 1440;

  /// 缓存版本号：当生成策略/参数调整后递增，避免命中旧缓存导致“还是低清海报”
  static const int _cacheVersion = 4;

  /// 用于通知 UI 重绘（从 fallback 切换到静态模糊图）
  static final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  static ValueNotifier<int> get ticker => _tick;

  static String _key(String id) => 'v$_cacheVersion:$id';

  /// 已生成的模糊图缓存 (key -> MemoryImage)
  static final Map<String, MemoryImage> _cache = {};

  /// 缓存访问顺序（用于 LRU 淘汰）
  static final List<String> _accessOrder = [];

  /// 正在生成中的任务（去重）
  static final Map<String, Completer<MemoryImage?>> _inFlight = {};

  /// 预热：在列表首屏时调用，尽量让"第一次点开"已生成
  static Future<void> warm(
    String id,
    ImageProvider imageProvider,
    BuildContext context,
  ) async {
    final key = _key(id);
    if (_cache.containsKey(key)) return;
    if (_inFlight.containsKey(key)) return;

    // 异步生成，不阻塞 UI
    _generateBlurred(id, imageProvider, context);
  }

  /// 获取模糊背景，如果未就绪则返回 fallback
  /// 返回值：(背景 ImageProvider, 是否为 fallback)
  static (ImageProvider, bool) getOrFallback(
    String id,
    ImageProvider imageProvider,
  ) {
    final key = _key(id);
    // 命中缓存
    if (_cache.containsKey(key)) {
      _touchAccess(key);
      return (_cache[key]!, false);
    }

    // 未命中，返回低清图作为 fallback（放大后天然发糊；不使用实时滤镜、不做淡入替换）
    return (ResizeImage(imageProvider, width: _fallbackResizeWidth), true);
  }

  /// 获取模糊背景的 Future（用于 fallback 后的淡入替换）
  static Future<MemoryImage?> getBlurredFuture(
    String id,
    ImageProvider imageProvider,
    BuildContext context,
  ) async {
    final key = _key(id);
    if (_cache.containsKey(key)) {
      _touchAccess(key);
      return _cache[key];
    }

    if (_inFlight.containsKey(key)) {
      return _inFlight[key]!.future;
    }

    return _generateBlurred(id, imageProvider, context);
  }

  /// 生成模糊图
  static Future<MemoryImage?> _generateBlurred(
    String id,
    ImageProvider imageProvider,
    BuildContext context,
  ) async {
    final completer = Completer<MemoryImage?>();
    final key = _key(id);
    _inFlight[key] = completer;

    try {
      // 1. 加载原图
      final imageStream = imageProvider.resolve(ImageConfiguration.empty);
      final imageCompleter = Completer<ui.Image>();

      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          imageCompleter.complete(info.image);
          imageStream.removeListener(listener);
        },
        onError: (e, _) {
          imageCompleter.completeError(e);
          imageStream.removeListener(listener);
        },
      );
      imageStream.addListener(listener);

      final image = await imageCompleter.future;

      // 2. 缩小 + 模糊（降低计算量，但不能太小，否则会“糊成一片”）
      // 目标：短边 ≈ _targetShortSide；保持一定分辨率以接近毛玻璃质感
      final shortestSide = (image.width < image.height) ? image.width : image.height;
      final baseScale = _targetShortSide / shortestSide.clamp(1, shortestSide);
      final scale = baseScale.clamp(0.1, 1.0);

      var targetWidth = (image.width * scale).round();
      var targetHeight = (image.height * scale).round();

      // 限制最大边，避免生成图过大占用内存（同时保持宽高比例）
      final maxSide = (targetWidth > targetHeight) ? targetWidth : targetHeight;
      if (maxSide > _maxSide) {
        final adjust = _maxSide / maxSide;
        targetWidth = (targetWidth * adjust).round();
        targetHeight = (targetHeight * adjust).round();
      }

      targetWidth = targetWidth.clamp(256, _maxSide);
      targetHeight = targetHeight.clamp(256, _maxSide);

      // 使用 PictureRecorder 绘制缩小版本
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // 绘制缩小的图片
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );

      final picture = recorder.endRecording();
      final smallImage = await picture.toImage(targetWidth, targetHeight);

      // 3. 应用模糊滤镜 + 轻微“取色”着色（更接近 iOS 毛玻璃质感）
      final blurRecorder = ui.PictureRecorder();
      final blurCanvas = Canvas(blurRecorder);

      final blurPaint = Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma);

      blurCanvas.drawImageRect(
        smallImage,
        Rect.fromLTWH(0, 0, smallImage.width.toDouble(), smallImage.height.toDouble()),
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        blurPaint,
      );

      // 从小图采样平均色，用作轻微取色叠层（避免“纯糊成一片”）
      final tint = await _sampleAverageColor(smallImage);
      blurCanvas.drawRect(
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..color = tint.withValues(alpha: 0.22),
      );

      final blurPicture = blurRecorder.endRecording();
      final blurredImage = await blurPicture.toImage(targetWidth, targetHeight);

      // 4. 转为 PNG 字节
      final byteData = await blurredImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        completer.complete(null);
        _inFlight.remove(id);
        return null;
      }

      final memoryImage = MemoryImage(byteData.buffer.asUint8List());

      // 5. 存入缓存
      _addToCache(key, memoryImage);

      completer.complete(memoryImage);
      _inFlight.remove(key);
      return memoryImage;
    } catch (e) {
      completer.complete(null);
      _inFlight.remove(key);
      return null;
    }
  }

  /// 添加到缓存（带 LRU 淘汰）
  static void _addToCache(String key, MemoryImage image) {
    // 淘汰最旧的
    while (_cache.length >= _maxCacheSize && _accessOrder.isNotEmpty) {
      final oldest = _accessOrder.removeAt(0);
      _cache.remove(oldest);
    }

    _cache[key] = image;
    _accessOrder.add(key);
    _tick.value++;
  }

  /// 更新访问顺序
  static void _touchAccess(String key) {
    _accessOrder.remove(key);
    _accessOrder.add(key);
  }

  /// 清空缓存
  static void clear() {
    _cache.clear();
    _accessOrder.clear();
    _inFlight.clear();
    _tick.value++;
  }

  static Future<Color> _sampleAverageColor(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const Color(0xFFB0B0B0);

    final bytes = byteData.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    final totalPixels = width * height;
    if (totalPixels <= 0) return const Color(0xFFB0B0B0);

    // 采样步长：越大越快
    final step = (totalPixels / 512).ceil().clamp(1, totalPixels);
    int r = 0, g = 0, b = 0, count = 0;

    for (int i = 0; i < totalPixels; i += step) {
      final idx = i * 4;
      if (idx + 2 >= bytes.length) break;
      r += bytes[idx];
      g += bytes[idx + 1];
      b += bytes[idx + 2];
      count++;
    }

    if (count == 0) return const Color(0xFFB0B0B0);
    return Color.fromARGB(255, (r ~/ count), (g ~/ count), (b ~/ count));
  }
}
