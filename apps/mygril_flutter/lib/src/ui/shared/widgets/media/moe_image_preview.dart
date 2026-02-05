/// 图片全屏预览组件
///
/// 特性：
/// - 平滑 Hero 动画过渡
/// - 双指缩放、双击放大
/// - 垂直滑动关闭
/// - 透明背景淡入效果
///
/// 使用示例：
/// ```dart
/// // 缩略图
/// GestureDetector(
///   onTap: () => MoeImagePreview.show(context, imageProvider, heroTag: 'image_1'),
///   child: Hero(
///     tag: 'image_1',
///     child: Image(...),
///   ),
/// )
/// ```
library;

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';

/// 图片全屏预览组件
class MoeImagePreview extends StatefulWidget {
  /// 图片提供者
  final ImageProvider imageProvider;

  /// Hero 动画标签（需与缩略图的 Hero tag 一致）
  final String heroTag;

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
    required this.imageProvider,
    required this.heroTag,
    this.backgroundColor,
    this.showCloseButton = true,
    this.minScale = 0.5,
    this.maxScale = 4.0,
  });

  /// 根据主题获取默认背景色
  /// - 浅色模式：深灰色 (#1A1A1A)，避免过于刺眼的纯黑
  /// - 深色模式：纯黑 (#000000)，与系统深色一致
  static Color getAdaptiveBackgroundColor(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? Colors.black : const Color(0xFF1A1A1A);
  }

  /// 显示图片预览（静态方法，方便调用）
  ///
  /// [context] 上下文
  /// [imageProvider] 图片提供者
  /// [heroTag] Hero 动画标签
  /// [backgroundColor] 背景颜色（null 时自动适配主题）
  /// [showCloseButton] 是否显示关闭按钮
  static Future<void> show(
    BuildContext context,
    ImageProvider imageProvider, {
    required String heroTag,
    Color? backgroundColor,
    bool showCloseButton = true,
    double minScale = 0.5,
    double maxScale = 4.0,
  }) async {
    // 在 push 之前获取背景色（此时 context 还有效）
    final bgColor = backgroundColor ?? getAdaptiveBackgroundColor(context);

    // 注意：系统输入法(IME)永远在应用之上，Flutter 不能把预览绘制到键盘上层。
    // 为了保证“图片预览覆盖全屏”，这里会临时隐藏键盘，并在关闭预览后恢复（不改变用户输入内容）。
    final focus = FocusManager.instance.primaryFocus;
    final shouldRestoreKeyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (shouldRestoreKeyboard) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }

    await Navigator.of(context, rootNavigator: true).push(
      _MoeImagePreviewRoute(
        imageProvider: imageProvider,
        heroTag: heroTag,
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

  // 关闭按钮动画控制器
  late final AnimationController _closeButtonController;

  @override
  void initState() {
    super.initState();
    _closeButtonController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    // 延迟显示关闭按钮
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _closeButtonController.forward();
    });
  }

  @override
  void dispose() {
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

  void _onVerticalDragStart(DragStartDetails details) {
    if (_scaleState != PhotoViewScaleState.initial) return;
    setState(() {
      _isDragging = true;
      _closeButtonController.reverse();
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isDragging) return;
    setState(() {
      _dragOffset += details.delta;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_isDragging) return;
    setState(() {
      _isDragging = false;
    });

    // 超过阈值则关闭，否则弹回
    if (_dragOffset.distance > 100) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _dragOffset = Offset.zero;
      });
      _closeButtonController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 获取实际背景色（支持自动适配主题）
    final bgColor = widget.backgroundColor ?? MoeImagePreview.getAdaptiveBackgroundColor(context);

    // 使用 FocusScope 隔离焦点，防止图片预览抢走输入框焦点导致键盘收起
    return FocusScope(
      canRequestFocus: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 禁用 Scaffold 的 resizeToAvoidBottomInset，保持键盘状态
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          onVerticalDragStart:
              _scaleState == PhotoViewScaleState.initial ? _onVerticalDragStart : null,
          onVerticalDragUpdate:
              _scaleState == PhotoViewScaleState.initial ? _onVerticalDragUpdate : null,
          onVerticalDragEnd:
              _scaleState == PhotoViewScaleState.initial ? _onVerticalDragEnd : null,
          onTap: () => Navigator.of(context).pop(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景层（响应透明度变化）
              AnimatedContainer(
                duration: _isDragging ? Duration.zero : const Duration(milliseconds: 200),
                color: bgColor.withOpacity(_backgroundOpacity),
              ),

              // 图片层（响应拖动变换）
              AnimatedContainer(
                duration: _isDragging ? Duration.zero : const Duration(milliseconds: 200),
                transform: _photoTransform,
                transformAlignment: Alignment.center,
                child: PhotoView(
                  imageProvider: widget.imageProvider,
                  heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
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
                          : event.cumulativeBytesLoaded /
                              (event.expectedTotalBytes ?? 1),
                    color: Colors.white54,
                    strokeWidth: 2,
                  ),
                ),
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
                ),
              ),
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
                    child: _CloseButton(onTap: () => Navigator.of(context).pop()),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 透明路由（支持 Hero 动画 + 淡入效果）
class _MoeImagePreviewRoute extends PageRoute<void> {
  final ImageProvider imageProvider;
  final String heroTag;
  final Color backgroundColor;
  final bool showCloseButton;
  final double minScale;
  final double maxScale;

  _MoeImagePreviewRoute({
    required this.imageProvider,
    required this.heroTag,
    required this.backgroundColor,
    required this.showCloseButton,
    required this.minScale,
    required this.maxScale,
  });

  @override
  bool get opaque => false; // 关键：让背景透明，Hero 动画更自然

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
      imageProvider: imageProvider,
      heroTag: heroTag,
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
    // 淡入淡出效果
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
