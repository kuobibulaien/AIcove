import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/blurred_background_service.dart';

/// 静态模糊叠层：把预先生成的重度模糊图按 [blur] 换算的不透明度盖在原图上，
/// 调节模糊时不跑实时滤镜。资源图优先用随包的 `_blur` 版本，其余来源后台生成并缓存。
class MoeStaticBlurLayer extends StatefulWidget {
  const MoeStaticBlurLayer({
    super.key,
    required this.source,
    required this.blur,
    this.alignment = Alignment.center,
  });

  /// 原图来源：资源名、本机路径、网络地址或 data URI。
  final String source;

  /// 模糊程度（0..30），0 时不绘制。
  final double blur;

  /// 铺满裁切的对齐，须与下方原图一致，否则两层错位。
  final Alignment alignment;

  static double opacityFor(double blur) {
    if (blur <= 0.1) return 0;
    return Curves.easeOut.transform((blur / 30).clamp(0.0, 1.0));
  }

  @override
  State<MoeStaticBlurLayer> createState() => _MoeStaticBlurLayerState();
}

class _MoeStaticBlurLayerState extends State<MoeStaticBlurLayer> {
  String? _source;
  ImageProvider? _provider;

  ImageProvider? _generated(String source) {
    if (_source != source) {
      _source = source;
      _provider = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _source != source) return;
        unawaited(
          BlurredBackgroundService.ensureBlur(source).then((provider) {
            if (!mounted || _source != source) return;
            if (identical(_provider, provider)) return;
            setState(() => _provider = provider);
          }),
        );
      });
    }
    return _provider;
  }

  Widget _image(ImageProvider provider) => SizedBox.expand(
    child: Image(
      image: provider,
      fit: BoxFit.cover,
      alignment: widget.alignment,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final opacity = MoeStaticBlurLayer.opacityFor(widget.blur);
    if (opacity <= 0) return const SizedBox.shrink();
    final source = widget.source;
    final blurAsset = BlurredBackgroundService.deriveBlurAssetPath(source);
    final Widget layer;
    if (blurAsset != null) {
      layer = SizedBox.expand(
        child: Image.asset(
          blurAsset,
          fit: BoxFit.cover,
          alignment: widget.alignment,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) {
            final provider = _generated(source);
            return provider == null
                ? const SizedBox.shrink()
                : _image(provider);
          },
        ),
      );
    } else {
      final provider = _generated(source);
      layer = provider == null ? const SizedBox.shrink() : _image(provider);
    }
    return IgnorePointer(
      child: Opacity(opacity: opacity, child: layer),
    );
  }
}
