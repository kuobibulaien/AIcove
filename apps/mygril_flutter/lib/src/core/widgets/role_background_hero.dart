import 'package:flutter/material.dart';
import 'smooth_clip.dart';
import '../utils/role_transition_tags.dart';
import '../utils/blurred_background_cache.dart';

/// 角色背景 Hero 组件
///
/// 封装背景共享元素动画，支持圆角飞行插值。
/// 卡片端使用 borderRadius=16，详情页端使用 borderRadius=0。
class RoleBackgroundHero extends StatefulWidget {
  /// 会话 ID（用于 Hero tag）
  final String conversationId;

  /// 海报图 Provider
  final ImageProvider imageProvider;

  /// 圆角半径（卡片端 16，详情页端 0）
  final double borderRadius;

  /// 是否为详情页（终点）
  final bool isDestination;

  const RoleBackgroundHero({
    super.key,
    required this.conversationId,
    required this.imageProvider,
    this.borderRadius = 16,
    this.isDestination = false,
  });

  @override
  State<RoleBackgroundHero> createState() => _RoleBackgroundHeroState();
}

class _RoleBackgroundHeroState extends State<RoleBackgroundHero> {
  ImageProvider? _blurredImage;
  bool _isFallback = true;

  @override
  void initState() {
    super.initState();
    _loadBackground();
  }

  void _loadBackground() {
    final (image, isFallback) = BlurredBackgroundCache.getOrFallback(
      widget.conversationId,
      widget.imageProvider,
    );
    _blurredImage = image;
    _isFallback = isFallback;

    // 如果是 fallback，异步加载真正的模糊图
    if (isFallback && widget.isDestination) {
      _loadBlurredAsync();
    }
  }

  Future<void> _loadBlurredAsync() async {
    // 等待 Hero 动画完成后再替换（约 300ms）
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    final blurred = await BlurredBackgroundCache.getBlurredFuture(
      widget.conversationId,
      widget.imageProvider,
      context,
    );

    if (mounted && blurred != null) {
      setState(() {
        _blurredImage = blurred;
        _isFallback = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: RoleTransitionTags.bg(widget.conversationId),
      flightShuttleBuilder: _buildFlightShuttle,
      child: _buildBackground(),
    );
  }

  /// 飞行过程中的 widget（圆角插值）
  Widget _buildFlightShuttle(
    BuildContext flightContext,
    Animation<double> animation,
    HeroFlightDirection flightDirection,
    BuildContext fromHeroContext,
    BuildContext toHeroContext,
  ) {
    // 获取起点和终点的圆角
    final fromRadius = flightDirection == HeroFlightDirection.push ? 16.0 : 0.0;
    final toRadius = flightDirection == HeroFlightDirection.push ? 0.0 : 16.0;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final currentRadius = lerpDouble(fromRadius, toRadius, animation.value) ?? fromRadius;
        return SmoothClipRRect(
          radius: currentRadius,
          child: _buildBackgroundImage(),
        );
      },
    );
  }

  Widget _buildBackground() {
    if (widget.borderRadius > 0) {
      return SmoothClipRRect(
        radius: widget.borderRadius,
        child: _buildBackgroundImage(),
      );
    }
    return _buildBackgroundImage();
  }

  Widget _buildBackgroundImage() {
    final image = _blurredImage ?? widget.imageProvider;

    // 详情页：如果从 fallback 切换到 blurred，使用淡入动画
    if (widget.isDestination && !_isFallback) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: _buildImageWidget(image, key: ValueKey(_isFallback)),
      );
    }

    return _buildImageWidget(image);
  }

  Widget _buildImageWidget(ImageProvider image, {Key? key}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        image: DecorationImage(
          image: image,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// 线性插值辅助函数
double? lerpDouble(double a, double b, double t) {
  return a + (b - a) * t;
}
