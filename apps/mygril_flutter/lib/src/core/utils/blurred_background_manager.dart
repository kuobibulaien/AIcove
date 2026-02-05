import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 模糊背景管理器（文件存储版本）
///
/// 为每张图片生成对应的模糊图并存储到本地文件系统
///
/// 支持的图片格式：
/// - PNG (.png)
/// - JPEG (.jpg, .jpeg)
/// - WebP (.webp)
/// - GIF (.gif) - 仅第一帧
/// - BMP (.bmp)
/// - WBMP (.wbmp)
///
/// 生成的模糊图统一保存为PNG格式
class BlurredBackgroundManager {
  BlurredBackgroundManager._();

  static const double _blurSigma = 40;
  static const int _targetShortSide = 720;
  static const int _maxSide = 1440;

  static Directory? _cacheDir;

  /// 初始化缓存目录
  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;

    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/blurred_backgrounds');

    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }

    return _cacheDir!;
  }

  /// 根据图片内容生成唯一文件名
  static String _getBlurredFileName(Uint8List imageBytes) {
    final hash = md5.convert(imageBytes).toString();
    return 'blur_$hash.png';
  }

  /// 获取或生成模糊背景
  /// 返回模糊图的文件路径
  /// 支持格式：PNG, JPG, JPEG, WEBP, GIF, BMP
  static Future<String?> getOrGenerate(Uint8List imageBytes) async {
    try {
      final dir = await _getCacheDir();
      final fileName = _getBlurredFileName(imageBytes);
      final file = File('${dir.path}/$fileName');

      // 如果已存在，直接返回
      if (await file.exists()) {
        return file.path;
      }

      // 不存在，生成新的
      final blurredBytes = await _generateBlurred(imageBytes);
      if (blurredBytes == null) return null;

      await file.writeAsBytes(blurredBytes);
      return file.path;
    } catch (e) {
      print('[BlurredBackgroundManager] 获取/生成失败: $e');
      return null;
    }
  }

  /// 生成模糊图
  static Future<Uint8List?> _generateBlurred(Uint8List imageBytes) async {
    try {
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      // 计算缩放尺寸
      final shortestSide = (image.width < image.height) ? image.width : image.height;
      final baseScale = _targetShortSide / shortestSide.clamp(1, shortestSide);
      final scale = baseScale.clamp(0.1, 1.0);

      var targetWidth = (image.width * scale).round();
      var targetHeight = (image.height * scale).round();

      final maxSide = (targetWidth > targetHeight) ? targetWidth : targetHeight;
      if (maxSide > _maxSide) {
        final adjust = _maxSide / maxSide;
        targetWidth = (targetWidth * adjust).round();
        targetHeight = (targetHeight * adjust).round();
      }

      targetWidth = targetWidth.clamp(256, _maxSide);
      targetHeight = targetHeight.clamp(256, _maxSide);

      // 绘制缩小版本
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

      // 应用模糊
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

      // 采样平均色并叠加
      final tint = await _sampleAverageColor(smallImage);
      blurCanvas.drawRect(
        Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        Paint()..color = tint.withValues(alpha: 0.22),
      );

      final blurPicture = blurRecorder.endRecording();
      final blurredImage = await blurPicture.toImage(targetWidth, targetHeight);

      final byteData = await blurredImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      return byteData.buffer.asUint8List();
    } catch (e) {
      print('[BlurredBackgroundManager] 生成失败: $e');
      return null;
    }
  }

  static Future<Color> _sampleAverageColor(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const Color(0xFFB0B0B0);

    final bytes = byteData.buffer.asUint8List();
    final totalPixels = image.width * image.height;
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

  /// 清理所有缓存
  static Future<void> clearAll() async {
    try {
      final dir = await _getCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create();
      }
    } catch (e) {
      print('[BlurredBackgroundManager] 清理失败: $e');
    }
  }
}
