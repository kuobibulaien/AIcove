/// 图片全屏预览组件
///
/// 特性：
/// - 平滑 Hero 动画过渡
/// - 双指缩放、双击放大
/// - 垂直滑动关闭
/// - 透明背景淡入效果
/// - 左右滑动切换上/下一张图片（画廊模式）
///
/// 使用示例：
/// ```dart
/// // 单张预览
/// MoeImagePreview.show(context, imageProvider, heroTag: 'image_1');
///
/// // 画廊模式（左右滑动切换）
/// MoeImagePreview.showGallery(
///   context,
///   images: [
///     ImagePreviewItem(provider: img1, heroTag: 'image_1'),
///     ImagePreviewItem(provider: img2, heroTag: 'image_2'),
///   ],
///   initialIndex: 0,
/// );
/// ```
library;

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

/// 画廊模式中每张图片的数据
class ImagePreviewItem {
  final ImageProvider provider;
  final String heroTag;

  const ImagePreviewItem({required this.provider, required this.heroTag});
}

/// 图片全屏预览组件
class MoeImagePreview extends StatefulWidget {
  /// 图片列表（画廊模式）
  final List<ImagePreviewItem> images;

  /// 初始显示的图片索引
  final int initialIndex;

  /// 背景颜色（null 时自动根据主题适配：浅色模式用深灰，深色模式用纯黑）
  final Color? backgroundColor;

  /// 是否显示关闭按钮
  final bool showCloseButton;

  /// 最小缩放比例
  final double minScale;

  /// 最大缩放比例
  final double maxScale;

  const MoeImagePreview({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.backgroundColor,
    this.showCloseButton = true,
    this.minScale = 0.5,
    this.maxScale = 4.0,
  });

  /// 根据主题获取默认背景色
  static Color getAdaptiveBackgroundColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? Colors.black : const Color(0xFF1A1A1A);
  }

  /// 显示单张图片预览（保持向后兼容）
  static Future<void> show(
    BuildContext context,
    ImageProvider imageProvider, {
    required String heroTag,
    Color? backgroundColor,
    bool showCloseButton = true,
    double minScale = 0.5,
    double maxScale = 4.0,
  }) {
    return showGallery(
      context,
      images: [ImagePreviewItem(provider: imageProvider, heroTag: heroTag)],
      initialIndex: 0,
      backgroundColor: backgroundColor,
      showCloseButton: showCloseButton,
      minScale: minScale,
      maxScale: maxScale,
    );
  }

  /// 显示画廊模式预览（支持左右滑动切换图片）
  static Future<void> showGallery(
    BuildContext context, {
    required List<ImagePreviewItem> images,
    int initialIndex = 0,
    Color? backgroundColor,
    bool showCloseButton = true,
    double minScale = 0.5,
    double maxScale = 4.0,
  }) async {
    if (images.isEmpty) return;
    final safeIndex = initialIndex.clamp(0, images.length - 1);
    final bgColor = backgroundColor ?? getAdaptiveBackgroundColor(context);

    // 临时隐藏键盘
    final focus = FocusManager.instance.primaryFocus;
    final shouldRestoreKeyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (shouldRestoreKeyboard) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }

    await Navigator.of(context, rootNavigator: true).push(
      _MoeImagePreviewRoute(
        images: images,
        initialIndex: safeIndex,
        backgroundColor: bgColor,
        showCloseButton: showCloseButton,
        minScale: minScale,
        maxScale: maxScale,
      ),
    );

    if (shouldRestoreKeyboard) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focus != null && focus.canRequestFocus) {
          focus.requestFocus();
        }
        SystemChannels.textInput.invokeMethod('TextInput.show');
      });
    }
  }

  @override
  State<MoeImagePreview> createState() => _MoeImagePreviewState();
}

class _MoeImagePreviewState extends State<MoeImagePreview>
    with SingleTickerProviderStateMixin {
  // 拖动状态
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;
  PhotoViewScaleState _scaleState = PhotoViewScaleState.initial;

  // 多指触控追踪
  int _pointerCount = 0;

  // 当前页码
  late int _currentIndex;
  late PageController _pageController;

  // 关闭按钮动画控制器
  late final AnimationController _closeButtonController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _closeButtonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _closeButtonController.forward();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _closeButtonController.dispose();
    super.dispose();
  }

  // 计算背景透明度（根据拖动距离）
  double get _backgroundOpacity {
    return max(1.0 - _dragOffset.distance * 0.003, 0.0);
  }

  // 计算图片缩放（根据拖动距离）
  double get _photoScale {
    return max(1.0 - _dragOffset.distance * 0.001, 0.7);
  }

  // 构建变换矩阵
  Matrix4 get _photoTransform {
    final translation = Matrix4.translationValues(
      _dragOffset.dx,
      _dragOffset.dy,
      0.0,
    );
    final scale = Matrix4.diagonal3Values(_photoScale, _photoScale, 1.0);
    return translation * scale;
  }

  /// 是否允许 PageView 左右滑动（仅在未缩放、未拖动时允许）
  bool get _canSwipePage =>
      _scaleState == PhotoViewScaleState.initial && !_isDragging;

  void _onVerticalDragStart(DragStartDetails details) {
    if (_scaleState != PhotoViewScaleState.initial || _pointerCount > 1) return;
    setState(() {
      _isDragging = true;
      _closeButtonController.reverse();
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    if (_pointerCount > 1) {
      _cancelDrag();
      return;
    }
    setState(() {
      _dragOffset += details.delta;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    setState(() {
      _isDragging = false;
    });

    if (_dragOffset.distance > 100) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _dragOffset = Offset.zero;
      });
      _closeButtonController.forward();
    }
  }

  void _cancelDrag() {
    setState(() {
      _isDragging = false;
      _dragOffset = Offset.zero;
    });
    _closeButtonController.forward();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.backgroundColor ??
        MoeImagePreview.getAdaptiveBackgroundColor(context);
    final images = widget.images;
    final isSingle = images.length == 1;

    return FocusScope(
      canRequestFocus: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Listener(
          onPointerDown: (_) => _pointerCount++,
          onPointerUp: (_) => _pointerCount = max(_pointerCount - 1, 0),
          onPointerCancel: (_) => _pointerCount = max(_pointerCount - 1, 0),
          child: GestureDetector(
            onVerticalDragStart: _scaleState == PhotoViewScaleState.initial
                ? _onVerticalDragStart
                : null,
            onVerticalDragUpdate: _scaleState == PhotoViewScaleState.initial
                ? _onVerticalDragUpdate
                : null,
            onVerticalDragEnd: _scaleState == PhotoViewScaleState.initial
                ? _onVerticalDragEnd
                : null,
            onTap: () => Navigator.of(context).pop(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 背景层
                AnimatedContainer(
                  duration: _isDragging
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  color: bgColor.withOpacity(_backgroundOpacity),
                ),

                // 图片层（单张或画廊 PageView）
                AnimatedContainer(
                  duration: _isDragging
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  transform: _photoTransform,
                  transformAlignment: Alignment.center,
                  child: isSingle
                      ? PhotoViewGestureDetectorScope(
                          axis: Axis.vertical,
                          child: _buildPhotoView(images.first),
                        )
                      : _buildGalleryPageView(images),
                ),

                // 关闭按钮
                if (widget.showCloseButton)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 16,
                    right: 16,
                    child: FadeTransition(
                      opacity: _closeButtonController,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, -0.5),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: _closeButtonController,
                          curve: Curves.easeOut,
                        )),
                        child: _CloseButton(
                            onTap: () => Navigator.of(context).pop()),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 构建单张 PhotoView
  Widget _buildPhotoView(ImagePreviewItem item) {
    return PhotoView(
      imageProvider: item.provider,
      heroAttributes: PhotoViewHeroAttributes(tag: item.heroTag),
      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
      minScale: PhotoViewComputedScale.contained * widget.minScale,
      maxScale: PhotoViewComputedScale.covered * widget.maxScale,
      initialScale: PhotoViewComputedScale.contained,
      scaleStateChangedCallback: (state) {
        setState(() {
          _scaleState = state;
        });
      },
      loadingBuilder: (context, event) => Center(
        child: CircularProgressIndicator(
          value: event == null
              ? null
              : event.cumulativeBytesLoaded / (event.expectedTotalBytes ?? 1),
          color: Colors.white54,
          strokeWidth: 2,
        ),
      ),
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
      ),
    );
  }

  /// 构建画廊 PageView（左右滑动切换图片）
  Widget _buildGalleryPageView(List<ImagePreviewItem> images) {
    return PhotoViewGestureDetectorScope(
      axis: Axis.horizontal,
      child: PageView.builder(
        controller: _pageController,
        itemCount: images.length,
        // 图片放大后禁用左右滑动，避免和 PhotoView 平移手势冲突
        physics: _canSwipePage
            ? const BouncingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
            // 切换页面时重置缩放状态
            _scaleState = PhotoViewScaleState.initial;
          });
        },
        itemBuilder: (context, index) {
          final item = images[index];
          // 只给当前页加 Hero，避免多个 Hero 同 tag 冲突
          return PhotoView(
            imageProvider: item.provider,
            heroAttributes: index == widget.initialIndex
                ? PhotoViewHeroAttributes(tag: item.heroTag)
                : null,
            backgroundDecoration:
                const BoxDecoration(color: Colors.transparent),
            minScale: PhotoViewComputedScale.contained * widget.minScale,
            maxScale: PhotoViewComputedScale.covered * widget.maxScale,
            initialScale: PhotoViewComputedScale.contained,
            scaleStateChangedCallback: (state) {
              if (index == _currentIndex) {
                setState(() {
                  _scaleState = state;
                });
              }
            },
            loadingBuilder: (context, event) => Center(
              child: CircularProgressIndicator(
                value: event == null
                    ? null
                    : event.cumulativeBytesLoaded /
                        (event.expectedTotalBytes ?? 1),
                color: Colors.white54,
                strokeWidth: 2,
              ),
            ),
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
            ),
          );
        },
      ),
    );
  }
}

/// 透明路由（支持 Hero 动画 + 淡入效果）
class _MoeImagePreviewRoute extends PageRoute<void> {
  final List<ImagePreviewItem> images;
  final int initialIndex;
  final Color backgroundColor;
  final bool showCloseButton;
  final double minScale;
  final double maxScale;

  _MoeImagePreviewRoute({
    required this.images,
    required this.initialIndex,
    required this.backgroundColor,
    required this.showCloseButton,
    required this.minScale,
    required this.maxScale,
  });

  @override
  bool get opaque => false;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  bool get requestFocus => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return MoeImagePreview(
      images: images,
      initialIndex: initialIndex,
      backgroundColor: backgroundColor,
      showCloseButton: showCloseButton,
      minScale: minScale,
      maxScale: maxScale,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

/// 关闭按钮
class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.close, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
