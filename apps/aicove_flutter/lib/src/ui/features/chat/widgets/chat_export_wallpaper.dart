import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Owns one decoded wallpaper frame for the duration of an export.
Future<ui.Image> loadChatExportWallpaper(
  ImageProvider provider,
  BuildContext context,
) async {
  final result = Completer<ui.Image>();
  final stream = provider.resolve(createLocalImageConfiguration(context));
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!result.isCompleted) result.complete(info.image.clone());
      info.dispose();
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 20));
  } finally {
    stream.removeListener(listener);
  }
}

/// Scales to the image width, repeats whole tiles, and clips the final tile.
class ChatExportWallpaperPainter extends CustomPainter {
  const ChatExportWallpaperPainter({
    required this.image,
    required this.background,
    required this.maskOpacity,
    required this.blurSigma,
  });

  final ui.Image image;
  final Color background;
  final double maskOpacity;
  final double blurSigma;

  @override
  void paint(Canvas canvas, Size size) {
    final tileHeight = size.width * image.height / image.width;
    final source = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final mask = maskOpacity.clamp(0.0, 1.0);
    final sigma = blurSigma.clamp(0.0, 30.0);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (double y = 0; y < size.height; y += tileHeight) {
      final tile = Rect.fromLTWH(0, y, size.width, tileHeight);
      canvas.drawImageRect(image, source, tile, Paint());
      if (sigma > 0.1) {
        canvas.save();
        canvas.clipRect(tile);
        canvas.saveLayer(
          tile,
          Paint()
            ..color = Colors.white.withValues(
              alpha: Curves.easeOut.transform(sigma / 30),
            )
            ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        );
        canvas.drawImageRect(image, source, tile, Paint());
        canvas.restore();
        canvas.restore();
      }
      canvas.drawRect(
        tile,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              background.withValues(alpha: (mask + 0.12).clamp(0.0, 1.0)),
              background.withValues(alpha: mask * 0.9),
              background.withValues(alpha: mask),
            ],
          ).createShader(tile),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ChatExportWallpaperPainter oldDelegate) =>
      image != oldDelegate.image ||
      background != oldDelegate.background ||
      maskOpacity != oldDelegate.maskOpacity ||
      blurSigma != oldDelegate.blurSigma;
}
