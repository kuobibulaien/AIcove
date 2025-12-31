/// 视差滑动路由 - 实现类似鸿蒙NEXT/iOS风格的页面切换动画
/// 
/// 动画效果：
/// - 新页面从右侧滑入，左侧带阴影
/// - 底层页面微幅左移（视差跟随效果）
/// 
/// 更新记录：
/// - 2025-12-02: 创建并调优参数
import 'package:flutter/material.dart';

/// ============================================================
/// 视差滑动路由配置
/// ============================================================

class ParallaxSlideConfig {
  /// 进入动画时长
  final Duration duration;
  
  /// 返回动画时长
  final Duration reverseDuration;
  
  /// 动画曲线
  final Curve curve;
  
  /// 底层页面位移比例（0-1），如 0.08 表示左移 8%
  final double secondarySlideRatio;
  
  /// 新页面左侧阴影
  final BoxShadow? shadow;

  const ParallaxSlideConfig({
    this.duration = const Duration(milliseconds: 400),
    this.reverseDuration = const Duration(milliseconds: 350),
    this.curve = Curves.fastOutSlowIn,
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
      curve: config.curve,
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
    ).chain(CurveTween(curve: config.curve));

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
    final slideIn = Tween(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).chain(CurveTween(curve: config.curve));

    return SlideTransition(
      position: animation.drive(slideIn),
      child: config.shadow != null
          ? DecoratedBox(
              decoration: BoxDecoration(boxShadow: [config.shadow!]),
              child: child,
            )
          : child,
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
