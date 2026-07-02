import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'avatar_helper.dart';
import 'data_image.dart';

/// 统一的角色模糊背景服务。
///
/// - 文件层：将生成后的模糊图持久化到本地
/// - 内存层：对热点 ImageProvider 做轻量 LRU 缓存
/// - 并发层：对同一来源的生成任务做 in-flight 去重
class BlurredBackgroundService {
  BlurredBackgroundService._();

  static const int _cacheVersion = 1;
  static const int _maxMemoryEntries = 12;
  static const double _blurSigma = 40;
  static const int _targetShortSide = 480;
  static const int _maxSide = 960;
  static const int _jpegQuality = 65;
  static const double _tintAlpha = 0.22;

  static Directory? _cacheDir;
  static final ValueNotifier<int> _tick = ValueNotifier<int>(0);
  static final Map<String, ImageProvider> _memoryCache = {};
  static final List<String> _accessOrder = [];
  static final Map<String, Completer<ImageProvider?>> _inFlight = {};

  static ValueNotifier<int> get ticker => _tick;

  static Future<void> init() async {
    await _getCacheDir();
    _tick.value++;
  }

  static String? pickPreferredSource({
    required String? characterImage,
    required String? avatarUrl,
  }) {
    final character = characterImage?.trim();
    if (character != null && character.isNotEmpty) return character;

    final avatar = avatarUrl?.trim();
    if (avatar != null && avatar.isNotEmpty) return avatar;
    return null;
  }

  static String? deriveBlurAssetPath(String? originalSource) {
    if (originalSource == null) return null;
    final trimmed = originalSource.trim();
    if (!trimmed.startsWith('assets/')) return null;
    final dot = trimmed.lastIndexOf('.');
    if (dot <= 0) return null;
    return '${trimmed.substring(0, dot)}_blur${trimmed.substring(dot)}';
  }

  static bool isNetworkSource(String? source) {
    final trimmed = source?.trim();
    if (trimmed == null || trimmed.isEmpty) return false;
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  static bool shouldPreGenerateEagerly(String? source) {
    final fingerprint = _sourceFingerprint(source);
    return fingerprint != null && !isNetworkSource(source);
  }

  static bool hasBlur(String? source) {
    final fingerprint = _sourceFingerprint(source);
    if (fingerprint == null) return false;

    final key = _key(fingerprint);
    if (_memoryCache.containsKey(key)) return true;
    if (_cacheDir == null) {
      unawaited(init());
      return false;
    }

    final path = _pathForSource(fingerprint);
    return File(path).existsSync();
  }

  static ImageProvider? getBlurProvider(String? source) {
    final fingerprint = _sourceFingerprint(source);
    if (fingerprint == null) return null;
    if (_cacheDir == null) {
      unawaited(init());
      return null;
    }

    final key = _key(fingerprint);
    final cached = _memoryCache[key];
    if (cached != null) {
      _touch(key);
      return cached;
    }

    final file = File(_pathForSource(fingerprint));
    if (!file.existsSync()) return null;

    final provider = FileImage(file);
    _remember(key, provider);
    return provider;
  }

  static Future<ImageProvider?> ensureBlur(
    String? source, {
    bool allowNetwork = true,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final rawSource = source?.trim();
    if (rawSource == null || rawSource.isEmpty) return null;

    final fingerprint = _sourceFingerprint(rawSource);
    if (fingerprint == null) return null;
    if (!allowNetwork && isNetworkSource(rawSource)) return null;

    final key = _key(fingerprint);
    final cached = getBlurProvider(rawSource);
    if (cached != null) return cached;

    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight.future;

    final completer = Completer<ImageProvider?>();
    _inFlight[key] = completer;

    try {
      await _getCacheDir();
      final diskCached = getBlurProvider(rawSource);
      if (diskCached != null) {
        completer.complete(diskCached);
        return diskCached;
      }

      final bytes = await _generateBlurBytes(rawSource)
          .timeout(timeout, onTimeout: () => null);
      if (bytes == null) {
        completer.complete(null);
        return null;
      }

      final file = File(_pathForSource(fingerprint));
      await file.parent.create(recursive: true);

      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsBytes(bytes, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);

      final provider = MemoryImage(bytes);
      _remember(key, provider);
      _tick.value++;
      completer.complete(provider);
      return provider;
    } catch (error) {
      debugPrint('[BlurService] ensureBlur failed: $error');
      completer.complete(null);
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 仅清理内存层缓存。
  ///
  /// 文件缓存以来源指纹为 key，多个角色可能共享同一张模糊图；
  /// 这里不直接删文件，避免误删共享资源。
  static Future<void> evict(String? source) async {
    final fingerprint = _sourceFingerprint(source);
    if (fingerprint == null) return;

    final key = _key(fingerprint);
    _memoryCache.remove(key);
    _accessOrder.remove(key);
    _tick.value++;
  }

  static Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;

    final appDir = await getApplicationDocumentsDirectory();
    _cacheDir = Directory('${appDir.path}/blurred_backgrounds');
    if (!await _cacheDir!.exists()) {
      await _cacheDir!.create(recursive: true);
    }
    return _cacheDir!;
  }

  static String? _sourceFingerprint(String? source) {
    final trimmed = source?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    final bytes = decodeDataImage(trimmed);
    if (bytes != null) {
      return 'data:${md5.convert(bytes)}';
    }

    final clean = AvatarHelper.cleanUrl(trimmed);
    final isAsset =
        clean.startsWith('assets/') || clean.startsWith('packages/');
    if (isAsset || isNetworkSource(clean)) {
      return clean;
    }

    try {
      final file = File(clean);
      if (file.existsSync()) {
        final stat = file.statSync();
        return '$clean#${stat.modified.millisecondsSinceEpoch}:${stat.size}';
      }
    } catch (error) {
      debugPrint('[BlurService] file stat failed: $error');
    }

    return clean;
  }

  static String _key(String fingerprint) =>
      'v$_cacheVersion:${md5.convert(fingerprint.codeUnits)}';

  static String _pathForSource(String fingerprint) {
    final digest = md5.convert(fingerprint.codeUnits).toString();
    return '${_cacheDir!.path}/v${_cacheVersion}_$digest.jpg';
  }

  static void _remember(String key, ImageProvider provider) {
    _memoryCache[key] = provider;
    _touch(key);

    while (_memoryCache.length > _maxMemoryEntries && _accessOrder.isNotEmpty) {
      final oldest = _accessOrder.removeAt(0);
      _memoryCache.remove(oldest);
    }
  }

  static void _touch(String key) {
    _accessOrder.remove(key);
    _accessOrder.add(key);
  }

  static Future<Uint8List?> _generateBlurBytes(String source) async {
    final provider = _buildProvider(source);
    if (provider == null) return null;

    final image = await _resolveUiImage(provider);

    final shortestSide =
        image.width < image.height ? image.width : image.height;
    final baseScale = _targetShortSide / shortestSide.clamp(1, shortestSide);
    final scale = baseScale.clamp(0.1, 1.0);

    var targetWidth = (image.width * scale).round();
    var targetHeight = (image.height * scale).round();

    final maxSide = targetWidth > targetHeight ? targetWidth : targetHeight;
    if (maxSide > _maxSide) {
      final adjust = _maxSide / maxSide;
      targetWidth = (targetWidth * adjust).round();
      targetHeight = (targetHeight * adjust).round();
    }

    targetWidth = targetWidth.clamp(160, _maxSide);
    targetHeight = targetHeight.clamp(160, _maxSide);

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

    final blurRecorder = ui.PictureRecorder();
    final blurCanvas = Canvas(blurRecorder);
    final blurPaint = Paint()
      ..imageFilter =
          ui.ImageFilter.blur(sigmaX: _blurSigma, sigmaY: _blurSigma);
    blurCanvas.drawImageRect(
      smallImage,
      Rect.fromLTWH(
        0,
        0,
        smallImage.width.toDouble(),
        smallImage.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      blurPaint,
    );

    final tint = await _sampleAverageColor(smallImage);
    blurCanvas.drawRect(
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      Paint()..color = tint.withValues(alpha: _tintAlpha),
    );

    final blurPicture = blurRecorder.endRecording();
    final blurredImage = await blurPicture.toImage(targetWidth, targetHeight);
    final rgbaBytes =
        await blurredImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgbaBytes == null) return null;

    final jpgImage = img.Image.fromBytes(
      width: blurredImage.width,
      height: blurredImage.height,
      bytes: rgbaBytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

    return Uint8List.fromList(
      img.encodeJpg(jpgImage, quality: _jpegQuality),
    );
  }

  static ImageProvider? _buildProvider(String source) {
    final helper = AvatarHelper(
      characterImage: source,
      displayName: '',
    );
    return helper.getCharacterProvider();
  }

  static Future<ui.Image> _resolveUiImage(ImageProvider provider) async {
    final stream = provider.resolve(ImageConfiguration.empty);
    final completer = Completer<ui.Image>();

    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (error, _) {
        completer.completeError(error);
        stream.removeListener(listener);
      },
    );

    stream.addListener(listener);
    return completer.future;
  }

  static Future<Color> _sampleAverageColor(ui.Image image) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return const Color(0xFFB0B0B0);

    final bytes = byteData.buffer.asUint8List();
    final totalPixels = image.width * image.height;
    if (totalPixels <= 0) return const Color(0xFFB0B0B0);

    final step = (totalPixels / 512).ceil().clamp(1, totalPixels);
    var r = 0;
    var g = 0;
    var b = 0;
    var count = 0;

    for (var i = 0; i < totalPixels; i += step) {
      final idx = i * 4;
      if (idx + 2 >= bytes.length) break;
      r += bytes[idx];
      g += bytes[idx + 1];
      b += bytes[idx + 2];
      count++;
    }

    if (count == 0) return const Color(0xFFB0B0B0);
    return Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
  }
}
