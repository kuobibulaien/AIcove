import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../ui/theme/tokens.dart';
import 'data_image.dart';

/// 角色头像/图片统一处理工具类
///
/// 设计说明：
/// - avatarUrl: 专门用于头像显示，可能带裁剪标记（如 #top）
/// - characterImage: 用于完整立绘展示
///
/// 优先级规则：
/// - 头像场景：avatarUrl → characterImage（因为 avatarUrl 专为头像设计）
/// - 立绘场景：characterImage → avatarUrl
class AvatarHelper {
  final String? avatarUrl;
  final String? characterImage;
  final String displayName;

  const AvatarHelper({
    this.avatarUrl,
    this.characterImage,
    required this.displayName,
  });

  /// 解析 URL 中的对齐标记（如 #top -> Alignment.topCenter）
  static Alignment parseAlignment(String? url) {
    if (url == null) return Alignment.center;
    if (url.contains('#top')) return Alignment.topCenter;
    if (url.contains('#bottom')) return Alignment.bottomCenter;
    return Alignment.center;
  }

  /// 移除 URL 中的对齐标记
  static String cleanUrl(String url) => url.split('#').first;

  /// 获取头像对齐方式（用于头像场景）
  Alignment get avatarAlignment => parseAlignment(avatarUrl);

  // ==================== 头像场景（avatarUrl 优先）====================

  /// 构建头像 Widget（用于消息列表、聊天设置等头像显示场景）
  /// 优先级：avatarUrl → characterImage → fallback
  Widget buildAvatarWidget({
    BoxFit fit = BoxFit.cover,
    Widget? fallback,
  }) {
    final fallbackWidget = fallback ?? _buildFallbackLetter();

    // 1. 尝试 avatarUrl
    final avatarWidget = _buildImageFromUrl(
      avatarUrl,
      fit: fit,
      fallback: fallbackWidget,
      useAlignment: true, // 头像场景使用对齐标记
    );
    if (avatarWidget != null) return avatarWidget;

    // 2. 尝试 characterImage
    final charWidget = _buildImageFromUrl(
      characterImage,
      fit: fit,
      fallback: fallbackWidget,
      useAlignment: false,
    );
    if (charWidget != null) return charWidget;

    // 3. fallback
    return fallbackWidget;
  }

  /// 获取头像 ImageProvider（用于预热、缓存等场景）
  /// 优先级：avatarUrl → characterImage
  ImageProvider? getAvatarProvider() {
    return _getProviderFromUrl(avatarUrl) ??
        _getProviderFromUrl(characterImage);
  }

  /// 获取头像字节（用于需要原始数据的场景）
  /// 优先级：avatarUrl → characterImage
  Future<Uint8List?> getAvatarBytes() async {
    return await _getBytesFromUrl(avatarUrl) ??
        await _getBytesFromUrl(characterImage);
  }

  // ==================== 立绘场景（characterImage 优先）====================

  /// 构建立绘 Widget（用于角色卡片、详情页等完整展示场景）
  /// 优先级：characterImage → avatarUrl → fallback
  Widget buildCharacterWidget({
    BoxFit fit = BoxFit.cover,
    Widget? fallback,
  }) {
    final fallbackWidget = fallback ?? _buildFallbackLetter();

    // 1. 尝试 characterImage
    final charWidget = _buildImageFromUrl(
      characterImage,
      fit: fit,
      fallback: fallbackWidget,
      useAlignment: false,
    );
    if (charWidget != null) return charWidget;

    // 2. 尝试 avatarUrl
    final avatarWidget = _buildImageFromUrl(
      avatarUrl,
      fit: fit,
      fallback: fallbackWidget,
      useAlignment: false, // 立绘场景不使用对齐标记
    );
    if (avatarWidget != null) return avatarWidget;

    // 3. fallback
    return fallbackWidget;
  }

  /// 获取立绘 ImageProvider
  /// 优先级：characterImage → avatarUrl
  ImageProvider? getCharacterProvider() {
    return _getProviderFromUrl(characterImage) ??
        _getProviderFromUrl(avatarUrl);
  }

  /// 获取立绘字节
  /// 优先级：characterImage → avatarUrl
  Future<Uint8List?> getCharacterBytes() async {
    return await _getBytesFromUrl(characterImage) ??
        await _getBytesFromUrl(avatarUrl);
  }

  // ==================== 私有辅助方法 ====================

  Widget? _buildImageFromUrl(
    String? url, {
    required BoxFit fit,
    required Widget fallback,
    required bool useAlignment,
  }) {
    if (url == null || url.trim().isEmpty) return null;

    final trimmed = url.trim();

    // 1. base64 数据
    final bytes = decodeDataImage(trimmed);
    if (bytes != null) {
      return Image.memory(bytes, fit: fit, gaplessPlayback: true);
    }

    // 2. 网络图片
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: trimmed,
        fit: fit,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      );
    }

    // 3. asset / 本地文件
    final cleanPath = cleanUrl(trimmed);
    final alignment = useAlignment ? parseAlignment(trimmed) : Alignment.center;
    final isAsset =
        cleanPath.startsWith('assets/') || cleanPath.startsWith('packages/');

    if (isAsset) {
      return Image.asset(
        cleanPath,
        fit: fit,
        alignment: alignment,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => fallback,
      );
    }

    return Image.file(
      File(cleanPath),
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => fallback,
    );
  }

  ImageProvider? _getProviderFromUrl(String? url) {
    if (url == null || url.trim().isEmpty) return null;

    final trimmed = url.trim();

    // 1. base64 数据
    final bytes = decodeDataImage(trimmed);
    if (bytes != null) return MemoryImage(bytes);

    // 2. 网络图片
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return CachedNetworkImageProvider(trimmed);
    }

    // 3. asset / 本地文件
    final cleanPath = cleanUrl(trimmed);
    final isAsset =
        cleanPath.startsWith('assets/') || cleanPath.startsWith('packages/');
    if (isAsset) return AssetImage(cleanPath);
    return FileImage(File(cleanPath));
  }

  Future<Uint8List?> _getBytesFromUrl(String? url) async {
    if (url == null || url.trim().isEmpty) return null;

    final trimmed = url.trim();

    // 1. base64 数据
    final bytes = decodeDataImage(trimmed);
    if (bytes != null) return bytes;

    // 2. asset / 本地文件
    final cleanPath = cleanUrl(trimmed);
    if (cleanPath.startsWith('assets/') || cleanPath.startsWith('packages/')) {
      try {
        final data = await rootBundle.load(cleanPath);
        return data.buffer.asUint8List();
      } catch (_) {
        return null;
      }
    }

    try {
      final file = File(cleanPath);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Widget _buildFallbackLetter() {
    final letter = displayName.isNotEmpty ? displayName[0] : '新';
    return Center(
      child: Text(
        letter,
        style: const TextStyle(
          fontSize: 24,
          color: Color(0xFF999999),
          fontWeight: MoeFontWeights.emphasis,
        ),
      ),
    );
  }
}

/// Conversation 扩展方法，方便直接使用
