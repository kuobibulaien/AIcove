/// 视差滑动路由 - 直接对齐 Flutter 官方 Cupertino 页面转场
///
/// 动画效果：
/// - 新页面从右侧滑入
/// - 底层页面左移 1/3，和官方 iOS 转场一致
/// - 返回时沿用 Cupertino 的边缘返回手势和反向曲线
///
/// 更新记录：
/// - 2025-12-02: 创建并调优参数
/// - 2026-03-22: 切换为 Flutter 官方 Cupertino 转场标准
library;

import 'package:flutter/cupertino.dart';

/// Flutter 官方 Cupertino 前景页曲线。
const Curve kCupertinoPrimaryRouteCurve = Curves.fastEaseInToSlowEaseOut;

/// Flutter 官方 Cupertino 背景页曲线。
const Curve kCupertinoSecondaryRouteCurve = Curves.linearToEaseOut;

/// Flutter 官方 Cupertino 背景页反向曲线。
const Curve kCupertinoSecondaryRouteReverseCurve = Curves.easeInToLinear;

/// Flutter 官方 Cupertino 底层页左移比例。
const double kCupertinoSecondarySlideRatio = 1 / 3;

/// ============================================================
/// 视差滑动路由配置
/// ============================================================

class ParallaxSlideConfig {
  /// 进入动画时长。
  ///
  /// 直接使用 [ParallaxSlidePageRoute] 时会交给官方 [CupertinoPageRoute]，
  /// 这里保留字段仅用于兼容历史 helper API。
  final Duration duration;

  /// 返回动画时长。
  final Duration reverseDuration;

  /// 新页面进入曲线。
  final Curve primaryCurve;

  /// 新页面返回曲线。
  final Curve primaryReverseCurve;

  /// 底层页面左移曲线。
  final Curve secondaryCurve;

  /// 底层页面左移反向曲线。
  final Curve secondaryReverseCurve;

  /// 底层页面位移比例（0-1）。
  final double secondarySlideRatio;

  /// 新页面左侧阴影。
  ///
  /// 直接使用 [ParallaxSlidePageRoute] 时会沿用官方 Cupertino 阴影，
  /// 这里保留字段仅用于兼容历史 helper API。
  final BoxShadow? shadow;

  const ParallaxSlideConfig({
    this.duration = CupertinoRouteTransitionMixin.kTransitionDuration,
    this.reverseDuration = CupertinoRouteTransitionMixin.kTransitionDuration,
    this.primaryCurve = kCupertinoPrimaryRouteCurve,
    this.primaryReverseCurve = _kFlippedCupertinoPrimaryRouteCurve,
    this.secondaryCurve = kCupertinoSecondaryRouteCurve,
    this.secondaryReverseCurve = kCupertinoSecondaryRouteReverseCurve,
    this.secondarySlideRatio = kCupertinoSecondarySlideRatio,
    this.shadow = const BoxShadow(
      color: Color(0x33000000),
      blurRadius: 16,
      offset: Offset(-4, 0),
    ),
  });

  /// 默认配置
  static const defaultConfig = ParallaxSlideConfig();
}

/// ============================================================
/// go_router 辅助函数
/// ============================================================

/// 构建底层页面的视差动画（用于 go_router 的主页面）
///
/// 使用示例：
/// ```dart
/// GoRoute(
///   path: '/',
///   pageBuilder: (context, state) => CustomTransitionPage(
///     child: MainPage(),
///     transitionsBuilder: buildSecondaryParallaxTransition(),
///   ),
/// )
/// ```
Widget Function(BuildContext, Animation<double>, Animation<double>, Widget)
    buildSecondaryParallaxTransition({
  ParallaxSlideConfig config = ParallaxSlideConfig.defaultConfig,
}) {
  return (context, animation, secondaryAnimation, child) {
    final curvedSecondary = CurvedAnimation(
      parent: secondaryAnimation,
      curve: config.secondaryCurve,
      reverseCurve: config.secondaryReverseCurve,
    );

    final slideTween = Tween(
      begin: Offset.zero,
      end: Offset(-config.secondarySlideRatio, 0.0),
    );

    return SlideTransition(
      textDirection: Directionality.of(context),
      transformHitTests: false,
      position: curvedSecondary.drive(slideTween),
      child: child,
    );
  };
}

/// 构建新页面的滑入动画（用于 go_router 的目标页面）
///
/// 使用示例：
/// ```dart
/// GoRoute(
///   path: 'detail',
///   pageBuilder: (context, state) => CustomTransitionPage(
///     child: DetailPage(),
///     transitionDuration: Duration(milliseconds: 400),
///     transitionsBuilder: buildPrimaryParallaxTransition(),
///   ),
/// )
/// ```
Widget Function(BuildContext, Animation<double>, Animation<double>, Widget)
    buildPrimaryParallaxTransition({
  ParallaxSlideConfig config = ParallaxSlideConfig.defaultConfig,
}) {
  return (context, animation, secondaryAnimation, child) {
    final curvedPrimary = CurvedAnimation(
      parent: animation,
      curve: config.primaryCurve,
      reverseCurve: config.primaryReverseCurve,
    );

    final slideIn = Tween(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    );

    return SlideTransition(
      textDirection: Directionality.of(context),
      position: curvedPrimary.drive(slideIn),
      child: child,
    );
  };
}

/// ============================================================
/// Navigator.push 用的 PageRoute
/// ============================================================

/// 视差滑动路由（用于 Navigator.push）。
///
/// 直接复用 Flutter 官方 [CupertinoPageRoute]，让 push/pop、
/// 底层页视差和边缘返回手势都和官方实现保持一致。
class ParallaxSlidePageRoute<T> extends CupertinoPageRoute<T> {
  final ParallaxSlideConfig config;

  ParallaxSlidePageRoute({
    required Widget page,
    this.config = ParallaxSlideConfig.defaultConfig,
  }) : super(builder: (_) => page);
}

/// ============================================================
/// Navigator 扩展方法
/// ============================================================

extension ParallaxSlideNavigatorExtension on NavigatorState {
  /// 使用视差滑动动画导航到新页面
  Future<T?> pushParallaxSlide<T>({
    required Widget page,
    ParallaxSlideConfig config = ParallaxSlideConfig.defaultConfig,
  }) {
    return push<T>(ParallaxSlidePageRoute(page: page, config: config));
  }
}

const Curve _kFlippedCupertinoPrimaryRouteCurve = _FlippedCurve(
  kCupertinoPrimaryRouteCurve,
);

class _FlippedCurve extends Curve {
  const _FlippedCurve(this.curve);

  final Curve curve;

  @override
  double transform(double t) => 1.0 - curve.transform(1.0 - t);
}
