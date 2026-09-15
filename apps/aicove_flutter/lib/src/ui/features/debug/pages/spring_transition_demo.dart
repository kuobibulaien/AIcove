import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_physics/flutter_physics.dart' as physics;
import 'package:motor/motor.dart' as motor;

import '../../../shared/widgets/index.dart';
import '../../../theme/tokens.dart';

enum SpringTransitionDemo {
  motor('Motor'),
  flutter('官方弹簧'),
  physics('flutter_physics');

  const SpringTransitionDemo(this.label);
  final String label;
}

/// Gallery-only motion comparison, not an application navigation adapter.
/// Retains the route during exit so a new target can cancel that exit.
void openSpringTransitionDemo(BuildContext context, SpringTransitionDemo demo) {
  unawaited(
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        settings: RouteSettings(name: 'gallery/spring/${demo.name}'),
        opaque: false,
        barrierColor: null,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => _SpringDemoPage(demo: demo),
      ),
    ),
  );
}

// Identical parameters isolate the controller implementation, not its presets.
const _spring = SpringDescription(mass: 1, stiffness: 400, damping: 40);

class _Motion {
  const _Motion({
    required this.animation,
    required this.animateTo,
    required this.jumpTo,
    required this.dispose,
  });
  final Animation<double> animation;
  final TickerFuture Function(double target, double? velocity) animateTo;
  final ValueChanged<double> jumpTo;
  final VoidCallback dispose;

  factory _Motion.create(SpringTransitionDemo demo, TickerProvider vsync) {
    switch (demo) {
      case SpringTransitionDemo.motor:
        final c = motor.SingleMotionController(
          vsync: vsync,
          motion: const motor.SpringMotion(_spring),
        );
        return _Motion(
          animation: c,
          animateTo: (target, velocity) =>
              c.animateTo(target, withVelocity: velocity),
          jumpTo: (value) => c.value = value,
          dispose: c.dispose,
        );
      case SpringTransitionDemo.flutter:
        final c = AnimationController.unbounded(vsync: vsync);
        return _Motion(
          animation: c,
          animateTo: (target, velocity) {
            final simulation = SpringSimulation(
              _spring,
              c.value,
              target,
              velocity ?? c.velocity,
            );
            return target == 0
                ? c.animateBackWith(simulation)
                : c.animateWith(simulation);
          },
          jumpTo: (value) => c.value = value,
          dispose: c.dispose,
        );
      case SpringTransitionDemo.physics:
        final c = physics.PhysicsController.unbounded(
          value: 0,
          vsync: vsync,
          defaultPhysics: physics.Spring(description: _spring),
        );
        return _Motion(
          animation: c,
          animateTo: (target, velocity) =>
              c.animateTo(target, velocityOverride: velocity),
          jumpTo: (value) => c.value = value,
          dispose: c.dispose,
        );
    }
  }
}

class _SpringDemoPage extends StatefulWidget {
  const _SpringDemoPage({required this.demo});
  final SpringTransitionDemo demo;
  @override
  State<_SpringDemoPage> createState() => _SpringDemoPageState();
}

class _SpringDemoPageState extends State<_SpringDemoPage>
    with SingleTickerProviderStateMixin {
  late final _motion = _Motion.create(widget.demo, this);
  int _operation = 0;
  bool _started = false;
  bool _leaving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _moveTo(1);
    }
  }

  Future<void> _moveTo(double target, {double? velocity}) async {
    if (_leaving) return;
    final operation = ++_operation;
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.jumpTo(target);
    } else {
      try {
        await _motion.animateTo(target, velocity).orCancel;
      } on TickerCanceled {
        return;
      }
    }
    if (!mounted || operation != _operation || target != 0) return;
    _leaving = true;
    // Only the completed current exit removes this route. A canceled exit
    // must never pop the route after the user has re-entered it.
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _operation++;
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final sign = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _moveTo(0);
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Stable child: animation ticks only update its translation.
              AnimatedBuilder(
                animation: _motion.animation,
                child: GestureDetector(
                  key: const ValueKey('spring-demo-drag'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) {
                    _operation++;
                    _motion.jumpTo(_motion.animation.value);
                  },
                  onHorizontalDragUpdate: (details) => _motion.jumpTo(
                    (_motion.animation.value - sign * details.delta.dx / width)
                        .clamp(0.0, 1.0),
                  ),
                  onHorizontalDragEnd: (details) {
                    final velocity =
                        -sign * details.velocity.pixelsPerSecond.dx / width;
                    final target = velocity.abs() > 0.8
                        ? (velocity > 0 ? 1.0 : 0.0)
                        : (_motion.animation.value > 0.5 ? 1.0 : 0.0);
                    _moveTo(target, velocity: velocity);
                  },
                  onHorizontalDragCancel: () => _moveTo(1),
                  child: ColoredBox(
                    color: colors.bgMain,
                    child: MoePageScaffold(
                      backgroundColor: colors.bgMain,
                      appBar: MoeAppBar(
                        title: widget.demo.label,
                        leading: BackButton(onPressed: () => _moveTo(0)),
                      ),
                      body: SafeArea(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(24, 36, 24, 180),
                          children: [
                            Text(
                              '连续打断演示',
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '滑动页面，或快速交替点击底部按钮。\n返回途中点“重新进入”，可打断返回。',
                              style: TextStyle(
                                color: colors.textSecondary,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 32),
                            for (final label in [
                              '相同页面内容',
                              '相同无回弹参数',
                              '保留当前位置与速度',
                            ])
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Text(
                                  label,
                                  style: TextStyle(color: colors.text),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                builder: (_, child) => Transform.translate(
                  key: const ValueKey('spring-demo-translation'),
                  offset: Offset(
                    sign * (1 - _motion.animation.value) * width,
                    0,
                  ),
                  child: child,
                ),
              ),
              // Controls remain reachable while the page is moving.
              Positioned(
                left: MoeSpacing.md,
                right: MoeSpacing.md,
                bottom: MediaQuery.paddingOf(context).bottom + MoeSpacing.md,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Flex(
                      direction: MediaQuery.textScalerOf(context).scale(14) > 20
                          ? Axis.vertical
                          : Axis.horizontal,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          fit: FlexFit.loose,
                          child: SizedBox(
                            width: double.infinity,
                            child: MoeSecondaryButton(
                              key: const ValueKey('spring-demo-back'),
                              label: '返回',
                              onPressed: () => _moveTo(0),
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: MoeSpacing.sm,
                          height: MoeSpacing.sm,
                        ),
                        Flexible(
                          fit: FlexFit.loose,
                          child: SizedBox(
                            width: double.infinity,
                            child: MoePrimaryButton(
                              key: const ValueKey('spring-demo-reenter'),
                              label: '重新进入',
                              onPressed: () => _moveTo(1),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
