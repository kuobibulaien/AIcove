import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Experimental: ripple-style light/dark switch.
///
/// Sits above `MaterialApp` and owns the effective brightness: [themeMode] is
/// resolved here (system mode follows the platform brightness), and the
/// resolved light/dark mode is handed to [builder]. Whenever the effective
/// brightness changes — settings toggle, "follow system" toggle or the OS
/// switching on its own — the old frame is snapshotted before the new theme
/// is built, then erased by a circle growing from [_origin].
///
/// Origin: the last pointer-down if it happened within [_pointerWindow]
/// (the toggle that caused the change), otherwise the window center.
class ThemeRippleReveal extends StatefulWidget {
  const ThemeRippleReveal({
    super.key,
    required this.themeMode,
    required this.builder,
  });

  final ThemeMode themeMode;

  /// Receives [ThemeMode.light] or [ThemeMode.dark], never system.
  final Widget Function(BuildContext context, ThemeMode effectiveMode) builder;

  static const Duration duration = Duration(milliseconds: 650);
  static const Duration _pointerWindow = Duration(seconds: 1);

  @override
  State<ThemeRippleReveal> createState() => _ThemeRippleRevealState();
}

class _ThemeRippleRevealState extends State<ThemeRippleReveal>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ThemeRippleReveal.duration,
  )..addStatusListener(_onStatus);

  late Brightness _shown = _resolve();
  ui.Image? _snapshot;
  double _snapshotScale = 1;
  Offset _origin = Offset.zero;
  Offset? _lastPointer;
  DateTime? _lastPointerAt;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(ThemeRippleReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangePlatformBrightness() => _sync();

  Brightness _resolve() => switch (widget.themeMode) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  void _sync() {
    final target = _resolve();
    if (target != _shown) _reveal(target);
  }

  Future<void> _reveal(Brightness target) async {
    final generation = ++_generation;
    if (_snapshot != null) {
      _controller.stop();
      setState(_clearSnapshot);
    }
    final boundary = _boundaryKey.currentContext?.findRenderObject();
    // Skip the ripple while the window is hidden; unfocused still animates.
    final visible = switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached =>
        false,
      _ => true,
    };
    ui.Image? image;
    var scale = 1.0;
    if (visible && boundary is RenderRepaintBoundary && boundary.hasSize) {
      scale = View.of(context).devicePixelRatio;
      try {
        image = await boundary.toImage(pixelRatio: scale);
      } catch (_) {
        image = null;
      }
    }
    if (!mounted || generation != _generation) {
      image?.dispose();
      return;
    }
    if (image == null) {
      setState(() => _shown = target);
      return;
    }

    final size = (boundary as RenderRepaintBoundary).size;
    final pointerAt = _lastPointerAt;
    final recentTap = pointerAt != null &&
        DateTime.now().difference(pointerAt) < ThemeRippleReveal._pointerWindow;
    setState(() {
      _shown = target;
      _snapshot = image;
      _snapshotScale = scale;
      _origin = recentTap
          ? boundary.globalToLocal(_lastPointer!)
          : size.center(Offset.zero);
    });
    _controller.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(_clearSnapshot);
    }
  }

  void _clearSnapshot() {
    _snapshot?.dispose();
    _snapshot = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _clearSnapshot();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final mode = _shown == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _lastPointer = event.position;
        _lastPointerAt = DateTime.now();
      },
      child: Stack(
        alignment: Alignment.topLeft,
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(
            key: _boundaryKey,
            child: widget.builder(context, mode),
          ),
          if (snapshot != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => CustomPaint(
                    painter: _RipplePainter(
                      image: snapshot,
                      imageScale: _snapshotScale,
                      origin: _origin,
                      progress:
                          Curves.easeInOutCubic.transform(_controller.value),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Paints the old-theme snapshot everywhere except inside the growing circle.
class _RipplePainter extends CustomPainter {
  _RipplePainter({
    required this.image,
    required this.imageScale,
    required this.origin,
    required this.progress,
  });

  final ui.Image image;
  final double imageScale;
  final Offset origin;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final maxRadius = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((corner) => (corner - origin).distance).reduce(math.max);
    final radius = maxRadius * progress;

    final hole = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: origin, radius: radius));

    canvas.save();
    canvas.clipPath(hole);
    canvas.scale(1 / imageScale);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.image != image ||
      oldDelegate.origin != origin;
}
