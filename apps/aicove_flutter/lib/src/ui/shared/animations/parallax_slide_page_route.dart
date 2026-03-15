/// 视差滑动路由 - 实现类似鸿蒙NEXT/iOS风格的页面切换动画
///
/// 动画效果：
/// - 新页面从右侧滑入，左侧带阴影
/// - 底层页面微幅左移（视差跟随效果）
///
/// 更新记录：
/// - 2025-12-02: 创建并调优参数
library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

/// 鸿蒙风格前景页曲线：起步平稳，中后段柔和收束。
const Cubic kHarmonySmoothCurve = Cubic(0.4, 0.0, 0.4, 1.0);

/// 鸿蒙风格背景页曲线：更像被轻轻带走，减少左移的生硬感。
const Cubic kHarmonyFrictionCurve = Cubic(0.2, 0.0, 0.2, 1.0);

/// ============================================================
/// 视差滑动路由配置
/// ============================================================

class ParallaxSlideConfig {
  /// 进入动画时长
  final Duration duration;

  /// 返回动画时长
  final Duration reverseDuration;

  /// 新页面进入曲线
  final Curve primaryCurve;

  /// 底层页面左移曲线
  final Curve secondaryCurve;

  /// 底层页面位移比例（0-1），如 0.08 表示左移 8%
  final double secondarySlideRatio;

  /// 新页面左侧阴影
  final BoxShadow? shadow;

  const ParallaxSlideConfig({
    this.duration = kAnimPage,
    this.reverseDuration = kAnimPageReverse,
    this.primaryCurve = kHarmonySmoothCurve,
    this.secondaryCurve = kHarmonyFrictionCurve,
    this.secondarySlideRatio = 0.08,
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
    );

    final slideTween = Tween(
      begin: Offset.zero,
      end: Offset(-config.secondarySlideRatio, 0.0),
    );

    return SlideTransition(
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
    final slideIn = Tween(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).chain(CurveTween(curve: config.primaryCurve));

    return SlideTransition(
      position: animation.drive(slideIn),
      child: config.shadow != null
          ? DecoratedBox(
              decoration: BoxDecoration(boxShadow: [config.shadow!]),
              child: child,
            )
          : child,
    );
  };
}

/// ============================================================
/// Navigator.push 用的 PageRoute
/// ============================================================

/// 视差滑动路由（用于 Navigator.push）
class ParallaxSlidePageRoute<T> extends PageRoute<T> {
  final Widget page;
  final ParallaxSlideConfig config;

  ParallaxSlidePageRoute({
    required this.page,
    this.config = ParallaxSlideConfig.defaultConfig,
  });

  @override
  bool get opaque => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => config.duration;

  @override
  Duration get reverseTransitionDuration => config.reverseDuration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return page;
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 1. 进入动画：从右侧滑入
    final slideIn = Tween(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).chain(CurveTween(curve: config.primaryCurve));

    // 2. 被覆盖时的动画：微幅左移（视差跟随效果）
    final curvedSecondary = CurvedAnimation(
      parent: secondaryAnimation,
      curve: config.secondaryCurve,
    );
    final slideOut = Tween(
      begin: Offset.zero,
      end: Offset(-config.secondarySlideRatio, 0.0),
    );

    // 组合动画：先处理被覆盖时的左移，再处理进入动画
    Widget result = SlideTransition(
      position: curvedSecondary.drive(slideOut),
      child: child,
    );

    return SlideTransition(
      position: animation.drive(slideIn),
      child: config.shadow != null
          ? DecoratedBox(
              decoration: BoxDecoration(boxShadow: [config.shadow!]),
              child: result,
            )
          : result,
    );
  }
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
