import 'dart:async';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// 模糊背景生成器（静态存储版本）
///
/// 上传图片时立即生成模糊图并存储到数据库，不再使用内存缓存
class BlurredBackgroundGenerator {
  BlurredBackgroundGenerator._();

  /// 静态模糊强度
  static const double _blurSigma = 40;

  /// 生成静态模糊图时的目标短边尺寸
  static const int _targetShortSide = 720;

  /// 静态模糊图最大边
  static const int _maxSide = 1440;

  /// 从图片字节生成模糊背景（返回PNG字节）
  static Future<Uint8List?> generateFromBytes(Uint8List imageBytes) async {
    try {
      // 1. 解码图片
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 2. 计算缩放尺寸
      final shortestSide = (image.width < image.height) ? image.width : image.height;
      final baseScale = _targetShortSide / shortestSide.clamp(1, shortestSide);
      final scale = baseScale.clamp(0.1, 1.0);

      var targetWidth = (image.width * scale).round();
      var targetHeight = (image.height * scale).round();

      // 限制最大边
      final maxSide = (targetWidth > targetHeight) ? targetWidth : targetHeight;
      if (maxSide > _maxSide) {
        final adjust = _maxSide / maxSide;
        targetWidth = (targetWidth * adjust).round();
        targetHeight = (targetHeight * adjust).round();
      }

      targetWidth = targetWidth.clamp(256, _maxSide);
      targetHeight = targetHeight.clamp(256, _maxSide);

      // 3. 绘制缩小版本
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );

      final picture = recorder.endRecording();
      final smallImage = await picture.toImage(targetWidth, targetHeight);

      // 4. 应用模糊滤镜
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

      // 5. 采样平均色并叠加
      final tint = await _sampleAverageColor(smallImage);
      blurCanvas.drawRect(
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..color = tint.withValues(alpha: 0.22),
      );

      final blurPicture = blurRecorder.endRecording();
      final blurredImage = await blurPicture.toImage(targetWidth, targetHeight);

      // 6. 转为PNG字节
      final byteData = await blurredImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      return byteData.buffer.asUint8List();
    } catch (e) {
      print('[BlurredBackgroundGenerator] 生成失败: $e');
      return null;
    }
  }

  static Future<Color> _sampleAverageColor(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const Color(0xFFB0B0B0);

    final bytes = byteData.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    final totalPixels = width * height;
    if (totalPixels <= 0) return const Color(0xFFB0B0B0);

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
