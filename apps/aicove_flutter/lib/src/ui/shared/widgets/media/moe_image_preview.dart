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

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/buttons/moe_button_surface.dart';
import '../../../theme/tokens.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

import '../../../../core/media/media_asset.dart';
import '../../../../core/media/media_store.dart';
import '../moe_floating_surface.dart';
import '../moe_toast.dart';
import 'image_save.dart';

/// 画廊模式中每张图片的数据
///
/// 普通图片给 [provider]；存在共享媒体库里的图片给 [mediaId]，
/// 预览时再解析本机文件，并在只有缩略图时提供「加载原图」。
class ImagePreviewItem {
  final ImageProvider? provider;
  final String? mediaId;
  final String heroTag;

  const ImagePreviewItem({
    required ImageProvider this.provider,
    required this.heroTag,
  }) : mediaId = null;

  const ImagePreviewItem.media({
    required String this.mediaId,
    required this.heroTag,
  }) : provider = null;
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

  // 关闭、保存按钮动画控制器
  late final AnimationController _closeButtonController;

  bool _saving = false;

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

  /// 保存当前这张：点下去时就锁定图片，下载途中翻页也不会存错。
  Future<void> _saveCurrent() async {
    if (_saving) return;
    final item = widget.images[_currentIndex];
    setState(() => _saving = true);
    try {
      final mediaId = item.mediaId;
      final provider = item.provider;
      if (mediaId != null) {
        final file = await (await MediaStore.shared).original(mediaId);
        if (mounted) {
          await saveImageFileToDevice(context, file, namePrefix: 'image');
        }
      } else if (provider is FileImage) {
        await saveImageFileToDevice(
          context,
          provider.file,
          namePrefix: 'image',
        );
      } else if (provider is MemoryImage) {
        await saveImageBytesToDevice(
          context,
          provider.bytes,
          namePrefix: 'image',
        );
      } else if (provider is CachedNetworkImageProvider) {
        final file =
            await (provider.cacheManager ??
                    CachedNetworkImageProvider.defaultCacheManager)
                .getSingleFile(
                  provider.url,
                  key: provider.cacheKey ?? provider.url,
                  headers: provider.headers ?? const {},
                );
        if (mounted) {
          await saveImageFileToDevice(context, file, namePrefix: 'image');
        }
      } else if (provider is AssetBundleImageProvider) {
        final key = await provider.obtainKey(ImageConfiguration.empty);
        final data = await key.bundle.load(key.name);
        if (mounted) {
          await saveImageBytesToDevice(
            context,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            namePrefix: 'image',
          );
        }
      } else if (mounted) {
        MoeToast.show(context, '这张图片暂时无法保存');
      }
    } on OriginalMediaUnavailable catch (error) {
      if (mounted) MoeToast.show(context, error.toString());
    } catch (_) {
      if (mounted) MoeToast.error(context, '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 跟关闭按钮一起淡入、拖动关闭时一起隐藏。
  Widget _fadingControl({required Offset from, required Widget child}) {
    return FadeTransition(
      opacity: _closeButtonController,
      child: SlideTransition(
        position: Tween<Offset>(begin: from, end: Offset.zero).animate(
          CurvedAnimation(
            parent: _closeButtonController,
            curve: Curves.easeOut,
          ),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor =
        widget.backgroundColor ??
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
                    child: _fadingControl(
                      from: const Offset(0, -0.5),
                      child: _RoundButton(
                        icon: Icons.close,
                        tooltip: '关闭',
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),

                // 保存按钮
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 16,
                  right: 16,
                  child: _fadingControl(
                    from: const Offset(0, 0.5),
                    child: _RoundButton(
                      icon: Icons.download_rounded,
                      tooltip: '保存图片',
                      busy: _saving,
                      onTap: _saveCurrent,
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
  Widget _buildPhotoView(ImagePreviewItem item) =>
      _buildPhoto(item, withHero: true, index: 0);

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
        // 只给当前页加 Hero，避免多个 Hero 同 tag 冲突
        itemBuilder: (context, index) => _buildPhoto(
          images[index],
          withHero: index == widget.initialIndex,
          index: index,
        ),
      ),
    );
  }

  Widget _buildPhoto(
    ImagePreviewItem item, {
    required bool withHero,
    required int index,
  }) {
    Widget photo(ImageProvider provider) => PhotoView(
      imageProvider: provider,
      heroAttributes: withHero
          ? PhotoViewHeroAttributes(tag: item.heroTag)
          : null,
      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
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
              : event.cumulativeBytesLoaded / (event.expectedTotalBytes ?? 1),
          color: Colors.white54,
          strokeWidth: 2,
        ),
      ),
      errorBuilder: (context, error, stackTrace) => const _BrokenImage(),
    );

    final mediaId = item.mediaId;
    if (mediaId != null) {
      return _MediaPhoto(
        key: ValueKey(mediaId),
        mediaId: mediaId,
        builder: photo,
      );
    }
    return photo(item.provider!);
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage();

  @override
  Widget build(BuildContext context) => const Center(
    child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
  );
}

/// 共享媒体库里的图片：解析本机文件，文件到达时自动刷新；
/// 只有缩略图在本机时提供「加载原图」。
class _MediaPhoto extends StatefulWidget {
  const _MediaPhoto({super.key, required this.mediaId, required this.builder});

  final String mediaId;
  final Widget Function(ImageProvider provider) builder;

  @override
  State<_MediaPhoto> createState() => _MediaPhotoState();
}

class _MediaPhotoState extends State<_MediaPhoto> {
  StreamSubscription<String>? _arrivals;
  late Future<(File?, bool, bool)> _image = _load();
  bool _loadingOriginal = false;
  bool _originalFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_watchArrivals());
  }

  Future<void> _watchArrivals() async {
    final media = await MediaStore.shared;
    if (!mounted) return;
    _arrivals = media.arrivals.listen((id) {
      if (mounted && id == widget.mediaId) {
        setState(() {
          _image = _load();
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_arrivals?.cancel());
    super.dispose();
  }

  /// (显示用文件, 原图是否在本机, 记录是否存在)
  Future<(File?, bool, bool)> _load() async {
    final media = await MediaStore.shared;
    final record = await media.load(widget.mediaId);
    final original =
        record?.originalPath != null &&
        await File(record!.originalPath!).exists();
    return (await media.display(widget.mediaId), original, record != null);
  }

  Future<void> _loadOriginal() async {
    if (_loadingOriginal) return;
    setState(() {
      _loadingOriginal = true;
      _originalFailed = false;
    });
    try {
      final media = await MediaStore.shared;
      await media.original(widget.mediaId);
      final loaded = await _load();
      if (!mounted) return;
      setState(() {
        _image = Future.value(loaded);
      });
    } catch (_) {
      if (mounted) setState(() => _originalFailed = true);
    } finally {
      if (mounted) setState(() => _loadingOriginal = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(File?, bool, bool)>(
    future: _image,
    builder: (context, snapshot) {
      final data = snapshot.data;
      final file = data?.$1;
      final waiting =
          snapshot.connectionState == ConnectionState.waiting ||
          (data != null && data.$3);
      final photo = file != null
          ? widget.builder(FileImage(file))
          : waiting
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.white54,
                strokeWidth: 2,
              ),
            )
          : const _BrokenImage();
      if (data == null || !data.$3 || data.$2) return photo;
      return Stack(
        fit: StackFit.expand,
        children: [
          photo,
          Positioned(
            left: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: MoeFloatingSurface(
              radius: 999,
              child: TextButton(
                onPressed: _loadingOriginal ? null : _loadOriginal,
                style: TextButton.styleFrom(
                  foregroundColor: context.moeColors.text,
                  disabledForegroundColor: context.moeColors.textSecondary,
                  backgroundColor: Colors.transparent,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_loadingOriginal) ...[
                      SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.moeColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      _loadingOriginal
                          ? '加载原图中…'
                          : _originalFailed
                          ? '加载失败，点击重试'
                          : '加载原图',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
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

/// 看图页上的圆形按钮（关闭、保存）
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool busy;
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = context.moeColors.text;
    return Tooltip(
      message: tooltip,
      child: MoeButtonSurface(
        radius: 999,
        child: InkWell(
          onTap: busy ? null : onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: busy
                ? SizedBox.square(
                    dimension: 22,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    ),
                  )
                : Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
