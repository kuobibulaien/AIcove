import 'package:flutter/material.dart';

import '../../../../ui/theme/tokens.dart';

/// 在列表顶部继续下拉超过半屏时触发隐私空间入口。
///
/// 直接读指针位移而非滚动越界量：Android 夹紧滚动不产生位移，
/// iOS/macOS 回弹又带阻尼，都无法稳定换算成手指行程。
class PrivacySpacePullDetector extends StatefulWidget {
  const PrivacySpacePullDetector({
    super.key,
    required this.child,
    required this.onTriggered,
    this.topInset = 0,
  });

  final Widget child;
  final VoidCallback onTriggered;
  final double topInset;

  @override
  State<PrivacySpacePullDetector> createState() =>
      _PrivacySpacePullDetectorState();
}

class _PrivacySpacePullDetectorState extends State<PrivacySpacePullDetector> {
  static const _hintStartDistance = 24.0;

  final _progress = ValueNotifier<double>(0);
  bool _atTop = true;
  bool _armed = false;
  double _startY = 0;
  double _threshold = double.infinity;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _atTop =
          notification.metrics.pixels <= notification.metrics.minScrollExtent;
    }
    return false;
  }

  void _start(double y) {
    _armed = _atTop;
    _startY = y;
    _progress.value = 0;
  }

  void _update(double y) {
    if (!_armed) return;
    final distance = y - _startY;
    if (distance < -_hintStartDistance) {
      _armed = false;
      _progress.value = 0;
      return;
    }
    _progress.value = distance <= _hintStartDistance
        ? 0
        : ((distance - _hintStartDistance) / (_threshold - _hintStartDistance))
              .clamp(0.0, 1.0);
  }

  void _end() {
    final triggered = _armed && _progress.value >= 1;
    _armed = false;
    _progress.value = 0;
    if (triggered) widget.onTriggered();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        _threshold = constraints.maxHeight / 2;
        return Listener(
          onPointerDown: (e) => _start(e.position.dy),
          onPointerMove: (e) => _update(e.position.dy),
          onPointerUp: (_) => _end(),
          onPointerCancel: (_) => _end(),
          onPointerPanZoomStart: (_) => _start(0),
          onPointerPanZoomUpdate: (e) => _update(e.pan.dy),
          onPointerPanZoomEnd: (_) => _end(),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Stack(
              children: [
                Positioned.fill(child: widget.child),
                Positioned(
                  top: widget.topInset + 12,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _progress,
                      builder: (context, progress, _) {
                        if (progress <= 0) return const SizedBox.shrink();
                        final ready = progress >= 1;
                        return Opacity(
                          opacity: (progress * 1.5).clamp(0.0, 1.0),
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: colors.borderLight),
                                boxShadow: [
                                  BoxShadow(
                                    color: colors.glassShadow,
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      ready
                                          ? Icons.lock_open
                                          : Icons.lock_outline,
                                      size: 16,
                                      color: ready
                                          ? colors.primary
                                          : colors.muted,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      ready ? '松开进入隐私空间' : '继续下拉进入隐私空间',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: ready
                                            ? colors.primary
                                            : colors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
