/// MoeSegmentedControl - 滑块式分段切换
///
/// 在 2～4 个互斥选项间切换（如气泡／文档、左／右、纯色／模糊／玻璃）。
///
/// 设计要点（参照 iOS 26 UISegmentedControl、鸿蒙 SegmentButton 页签类）：
/// - 轨道是中性灰淡底（iOS tertiarySystemFill），不带强调色
/// - 纯色档：选中项是强调色淡染胶囊＋浮层描边（原 MoeToggleBar 的选中态），
///   拖动时直接跟手，不浮起
/// - 模糊／玻璃档（同一套体系）：静止时选中项是一块「压暗＋模糊」的凹槽，
///   像被按进轨道里；按住或拖动时浮起放大成一块玻璃（玻璃档为液态透镜，
///   模糊档回退毛玻璃），跟手移动；松手按临界阻尼弹簧落到
///   最近的选项，再收回凹槽。对应 WWDC25「Build a UIKit app with the new
///   design」：分段控件滑块在交互时变为液态玻璃；「Meet Liquid Glass」：玻璃
///   放大时模拟更厚的材质、更深的阴影与更强的透镜
/// - 选中文字用主文字色并加粗，未选中用次要文字色
/// - 点按其他选项时滑块直接滑过去，不浮起；系统「减少动态效果」时不放大
/// - 各项等宽；默认撑满父级，expanded 为 false 时按最长选项收宽
///
/// 使用示例：
/// ```dart
/// MoeSegmentedControl<ChatDisplayStyle>(
///   value: style,
///   segments: const [
///     MoeSegment(value: ChatDisplayStyle.bubble, label: '气泡'),
///     MoeSegment(value: ChatDisplayStyle.document, label: '文档'),
///   ],
///   onChanged: (value) => ...,
/// )
/// ```
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../theme/tokens.dart';
import '../moe_liquid_glass.dart';

/// 分段项
class MoeSegment<T> {
  const MoeSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// 滑块式分段切换
class MoeSegmentedControl<T> extends StatefulWidget {
  const MoeSegmentedControl({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
    this.height = 36,
    this.radius,
    this.expanded = true,
  }) : assert(segments.length >= 2);

  final T value;
  final List<MoeSegment<T>> segments;

  /// 为 null 时禁用。
  final ValueChanged<T>? onChanged;

  final double height;

  /// 轨道圆角；默认胶囊（高度一半）。
  final double? radius;

  /// 撑满父级宽度；为 false 时按最长选项等分收宽（可放进横向滚动）。
  final bool expanded;

  @override
  State<MoeSegmentedControl<T>> createState() => _MoeSegmentedControlState<T>();
}

class _MoeSegmentedControlState<T> extends State<MoeSegmentedControl<T>>
    with TickerProviderStateMixin {
  static const double _inset = 2;

  /// iOS thumb spring (Flutter CupertinoSlidingSegmentedControl): critically
  /// damped, so the thumb lands without bouncing.
  static const SpringDescription _spring = SpringDescription(
    mass: 1,
    stiffness: 503.551,
    damping: 44.8799,
  );

  /// Thumb position in segment units (0 = first segment).
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: _selectedIndex.toDouble(),
  );

  /// 0 = resting recess, 1 = lifted glass lens.
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 320),
  );

  int? _pressedIndex;
  bool _dragging = false;
  double _grabOffset = 0;
  int _hoverIndex = 0;

  int get _count => widget.segments.length;

  int get _selectedIndex {
    final index = widget.segments.indexWhere((s) => s.value == widget.value);
    return index < 0 ? 0 : index;
  }

  bool get _enabled => widget.onChanged != null;

  /// Frosted and glass share the recess-and-lens system; solid keeps the
  /// accent pill and never lifts.
  bool get _glassy =>
      (MoeGlassTheme.maybeOf(context)?.material ?? MoeSurfaceMaterial.solid) !=
      MoeSurfaceMaterial.solid;

  double get _segmentWidth {
    final width = context.size?.width ?? 0;
    return (width - _inset * 2) / _count;
  }

  /// Segment position (fractional) whose center sits under [dx].
  double _positionAt(double dx) => (dx - _inset) / _segmentWidth - 0.5;

  int _indexAt(double dx) =>
      _positionAt(dx).round().clamp(0, _count - 1).toInt();

  @override
  void didUpdateWidget(covariant MoeSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && _position.value != _selectedIndex) {
      _settleTo(_selectedIndex);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _settleTo(int index, {double velocity = 0}) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _position.value = index.toDouble();
      return;
    }
    _position.animateWith(
      SpringSimulation(_spring, _position.value, index.toDouble(), velocity),
    );
  }

  void _commit(int index) {
    final segment = widget.segments[index];
    if (segment.value == widget.value) return;
    HapticFeedback.selectionClick();
    widget.onChanged?.call(segment.value);
  }

  // ── Lifted drag: the thumb becomes a glass lens and follows the finger ──

  bool _onThumb(double dx) => (_positionAt(dx) - _position.value).abs() <= 0.5;

  void _beginDrag(double dx) {
    _position.stop();
    _dragging = true;
    _grabOffset = _positionAt(dx) - _position.value;
    _hoverIndex = _selectedIndex;
    if (_glassy && !MediaQuery.disableAnimationsOf(context)) _lift.forward();
    setState(() => _pressedIndex = null);
  }

  void _updateDrag(double dx) {
    final raw = _positionAt(dx) - _grabOffset;
    // Rubber band past either end, like iOS overdrag.
    final max = (_count - 1).toDouble();
    final pos = raw < 0
        ? raw * 0.25
        : raw > max
        ? max + (raw - max) * 0.25
        : raw;
    _position.value = pos;
    final hover = pos.round().clamp(0, _count - 1).toInt();
    if (hover != _hoverIndex) {
      _hoverIndex = hover;
      HapticFeedback.selectionClick();
      setState(() {});
    }
  }

  void _endDrag(double velocityPx) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = _segmentWidth == 0 ? 0.0 : velocityPx / _segmentWidth;
    // Commit where a flick would land, not only where the finger let go.
    final target = (_position.value + velocity * 0.12)
        .round()
        .clamp(0, _count - 1)
        .toInt();
    _settleTo(target, velocity: velocity);
    _lift.reverse();
    final segment = widget.segments[target];
    if (segment.value != widget.value) widget.onChanged?.call(segment.value);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackColor = isDark
        ? const Color(0x3D767680)
        : const Color(0x1F767680);
    final radius = widget.radius ?? widget.height / 2;
    final emphasized = _dragging ? _hoverIndex : _selectedIndex;

    Widget control = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _enabled
          ? (d) => setState(() => _pressedIndex = _indexAt(d.localPosition.dx))
          : null,
      onTapCancel: () => setState(() => _pressedIndex = null),
      onTapUp: _enabled
          ? (d) {
              setState(() => _pressedIndex = null);
              _commit(_indexAt(d.localPosition.dx));
            }
          : null,
      onLongPressStart: _enabled ? (d) => _beginDrag(d.localPosition.dx) : null,
      onLongPressMoveUpdate: _enabled
          ? (d) => _updateDrag(d.localPosition.dx)
          : null,
      onLongPressEnd: _enabled
          ? (d) => _endDrag(d.velocity.pixelsPerSecond.dx)
          : null,
      onHorizontalDragStart: _enabled
          ? (d) {
              if (_onThumb(d.localPosition.dx)) _beginDrag(d.localPosition.dx);
            }
          : null,
      onHorizontalDragUpdate: _enabled
          ? (d) => _dragging
                ? _updateDrag(d.localPosition.dx)
                : _commit(_indexAt(d.localPosition.dx))
          : null,
      onHorizontalDragEnd: _enabled
          ? (d) => _endDrag(d.velocity.pixelsPerSecond.dx)
          : null,
      onHorizontalDragCancel: () => _endDrag(0),
      child: Container(
        height: widget.height,
        padding: const EdgeInsets.all(_inset),
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: Listenable.merge([_position, _lift]),
                builder: (context, _) {
                  final x = _count == 1
                      ? 0.0
                      : -1 + 2 * _position.value / (_count - 1);
                  final lift = Curves.easeOutBack.transform(_lift.value);
                  return Align(
                    alignment: Alignment(x, 0),
                    child: FractionallySizedBox(
                      widthFactor: 1 / _count,
                      heightFactor: 1,
                      child: Transform.scale(
                        scaleX: 1 + 0.12 * lift,
                        scaleY: 1 + 0.32 * lift,
                        child: AnimatedScale(
                          duration: kAnimFast,
                          scale: _pressedIndex == _selectedIndex ? 0.95 : 1,
                          child: _Thumb(
                            radius: radius - _inset,
                            lift: _lift.value,
                            glassy: _glassy,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, segment) in widget.segments.indexed)
                  Expanded(
                    child: _SegmentLabel(
                      segment: segment,
                      selected: index == emphasized,
                      pressed: index == _pressedIndex && index != emphasized,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (!widget.expanded) control = IntrinsicWidth(child: control);

    return Semantics(
      container: true,
      child: Opacity(opacity: _enabled ? 1 : 0.45, child: control),
    );
  }
}

/// 滑块。纯色档为强调色淡染胶囊（原 MoeToggleBar 选中态）；模糊／玻璃档静止为
/// 「压暗＋模糊」的凹槽，[lift] 升起时交叉淡入一块玻璃（MoeLiquidGlass 跟随
/// 全局材质），只强调玻璃质感，不加强调色。
class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.radius,
    required this.lift,
    required this.glassy,
  });

  final double radius;
  final double lift;
  final bool glassy;

  static const double _recessBlur = 6;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    if (!glassy) {
      // Solid keeps the accent pill of the former MoeToggleBar.
      final colors = context.moeColors;
      final tint = colors.focus;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: tint.withValues(alpha: tint.a.clamp(0, isDark ? 0.28 : 0.22)),
          borderRadius: shape,
          border: Border.fromBorderSide(colors.floatingBorder),
        ),
      );
    }
    final recess = ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: _recessBlur, sigmaY: _recessBlur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: isDark ? 0.32 : 0.09),
            borderRadius: shape,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
    if (lift == 0) return recess;

    final glass = MoeLiquidGlass(
      quality: GlassQuality.standard,
      radius: radius,
      baseline: MoeMaterialBaseline.component,
      border: BorderSide(
        color: Colors.white.withValues(alpha: isDark ? 0.3 : 0.75),
        width: 0.8,
      ),
      // Thicker material when lifted: deeper, softer shadow.
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.34 : 0.16),
          offset: const Offset(0, 6),
          blurRadius: 18,
        ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.22),
        ),
        child: const SizedBox.expand(),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (lift < 1) Opacity(opacity: 1 - lift, child: recess),
        Opacity(opacity: lift.clamp(0, 1), child: glass),
      ],
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    required this.segment,
    required this.selected,
    required this.pressed,
  });

  final MoeSegment<dynamic> segment;
  final bool selected;
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final color = selected ? colors.text : colors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: segment.label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        duration: kAnimFast,
        opacity: pressed ? 0.3 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: 16, color: color),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: kAnimFast,
                  // Merge so labels keep the theme font fallback stack.
                  style: DefaultTextStyle.of(context).style.merge(
                    TextStyle(
                      fontSize: 14,
                      height: 1.2,
                      color: color,
                      fontWeight: selected
                          ? MoeFontWeights.emphasis
                          : MoeFontWeights.normal,
                    ),
                  ),
                  child: Text(
                    segment.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
