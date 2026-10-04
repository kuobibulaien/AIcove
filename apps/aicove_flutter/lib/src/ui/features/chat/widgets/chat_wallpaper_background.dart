import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/utils/blurred_background_service.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../features/chat/domain/conversation.dart';
import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

/// 聊天区底色：深色固定；浅色未自定义（或白色）时用默认聊天底色。
Color resolveChatBackgroundColor(BuildContext context, Color? lightSetting) {
  if (Theme.of(context).brightness == Brightness.dark) {
    return telegramChatBackgroundDark;
  }
  return lightSetting == null || lightSetting == Colors.white
      ? telegramChatBackground
      : lightSetting;
}

/// 非 data URI 的壁纸／图片地址转图片源；data URI 由调用方先行解码。
ImageProvider? chatImageProviderFor(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || trimmed.startsWith('data:image')) return null;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return CachedNetworkImageProvider(trimmed);
  }
  if (trimmed.startsWith('assets/') || trimmed.startsWith('packages/')) {
    return AssetImage(trimmed);
  }
  return FileImage(File(trimmed));
}

/// 会话壁纸层：图片＋静态模糊叠层＋渐变蒙层；无壁纸时回退底色或默认花纹。
/// 聊天页与「聊天界面」设置页共用，保证设置页背景就是实际聊天效果的预览。
class ChatWallpaperLayer extends StatefulWidget {
  const ChatWallpaperLayer({
    super.key,
    required this.image,
    required this.fallbackColor,
    this.maskOpacity = 0.8,
    this.blurSigma = 0,
  });

  ChatWallpaperLayer.forConversation({
    Key? key,
    required Conversation? conversation,
    required Color fallbackColor,
  }) : this(
         key: key,
         image: conversation?.chatBackgroundImage,
         fallbackColor: fallbackColor,
         maskOpacity: conversation?.chatBackgroundMaskOpacity ?? 0.8,
         blurSigma: conversation?.chatBackgroundBlurSigma ?? 0,
       );

  /// 壁纸地址：data URI、网络、资源或本地文件；空表示未设置。
  final String? image;
  final Color fallbackColor;
  final double maskOpacity;
  final double blurSigma;

  @override
  State<ChatWallpaperLayer> createState() => _ChatWallpaperLayerState();
}

class _ChatWallpaperLayerState extends State<ChatWallpaperLayer> {
  String? _staticBlurSource;
  ImageProvider? _staticBlurProvider;
  // data URI 解码结果按原串缓存，调节蒙层／模糊时不重复解码整张图。
  String? _decodedSource;
  Uint8List? _decodedBytes;

  @override
  Widget build(BuildContext context) {
    final fallbackColor = widget.fallbackColor;
    final raw = widget.image?.trim();
    if (raw == null || raw.isEmpty) {
      if (fallbackColor == telegramChatBackground ||
          fallbackColor == telegramChatBackgroundDark) {
        return const MoeChatWallpaper(child: SizedBox.expand());
      }
      return ColoredBox(color: fallbackColor);
    }

    final image = _buildBackgroundImage(raw);
    if (image == null) return ColoredBox(color: fallbackColor);
    final maskOpacity = widget.maskOpacity.clamp(0.0, 1.0);
    final topMaskOpacity = (maskOpacity + 0.12).clamp(0.0, 1.0);
    final blurSigma = widget.blurSigma.clamp(0.0, 30.0);
    final blurOverlayOpacity = _staticBlurOverlayOpacity(blurSigma);
    final blurOverlay = blurOverlayOpacity > 0
        ? _buildStaticBlurLayer(raw, opacity: blurOverlayOpacity)
        : null;

    return Container(
      color: fallbackColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          if (blurOverlay != null) blurOverlay,
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    fallbackColor.withValues(alpha: topMaskOpacity),
                    fallbackColor.withValues(
                      alpha: (maskOpacity * 0.9).clamp(0.0, 1.0),
                    ),
                    fallbackColor.withValues(alpha: maskOpacity),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double _staticBlurOverlayOpacity(double blurSigma) {
    if (blurSigma <= 0.1) return 0;
    return Curves.easeOut.transform((blurSigma / 30).clamp(0.0, 1.0));
  }

  Widget? _buildStaticBlurLayer(String source, {required double opacity}) {
    final blurAsset = BlurredBackgroundService.deriveBlurAssetPath(source);
    if (blurAsset == null) {
      _scheduleStaticBlur(source);
    }
    Widget? layer;
    if (blurAsset != null) {
      layer = SizedBox.expand(
        child: Image.asset(
          blurAsset,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) {
            final provider = _resolveStaticBlurProvider(source);
            if (provider == null) return const SizedBox.shrink();
            return _buildStaticBlurImage(provider);
          },
        ),
      );
    } else {
      final provider = _resolveStaticBlurProvider(source);
      if (provider != null) {
        layer = _buildStaticBlurImage(provider);
      }
    }

    if (layer == null) return null;
    return IgnorePointer(
      child: Opacity(
        key: const ValueKey<String>('chat_page_static_blur_layer'),
        opacity: opacity,
        child: layer,
      ),
    );
  }

  ImageProvider? _resolveStaticBlurProvider(String source) {
    if (_staticBlurSource != source) return null;
    return _staticBlurProvider;
  }

  Widget _buildStaticBlurImage(ImageProvider provider) {
    return SizedBox.expand(
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  void _scheduleStaticBlur(String source) {
    if (_staticBlurSource == source) return;
    _staticBlurSource = source;
    _staticBlurProvider = null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _staticBlurSource != source) return;
      unawaited(
        BlurredBackgroundService.ensureBlur(source).then((provider) {
          if (!mounted || _staticBlurSource != source) return;
          if (identical(_staticBlurProvider, provider)) return;
          setState(() {
            _staticBlurProvider = provider;
          });
        }),
      );
    });
  }

  Widget? _buildBackgroundImage(String raw) {
    if (_decodedSource != raw) {
      _decodedSource = raw;
      _decodedBytes = decodeDataImage(raw);
    }
    final bytes = _decodedBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }

    final provider = chatImageProviderFor(raw);
    if (provider == null) return null;
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}
