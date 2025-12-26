/// 原地展开路由 - 实现 Container Transform 动画效果
/// 
/// 使用方法：
/// ```dart
/// Navigator.of(context).push(
///   ExpandingPageRoute(
///     page: DetailPage(),
///     sourceRect: cardRect,  // 通过 RenderBox 获取
///     sourceRadius: 12.0,
///   ),
/// );
/// ```
/// 
/// 或使用扩展方法：
/// ```dart
/// Navigator.of(context).pushExpanding(
///   page: DetailPage(),
///   sourceContext: cardContext,
/// );
/// ```
/// 
/// 更新记录：
/// - 2025-12-01: 创建，实现"原地展开"动画效果
/// - 2025-12-08: 修复返回动画闪烁问题（背景层透明度随 progress 变化）
/// - 2025-12-08: 禁止底层页面左移动画（覆写 canTransitionFrom）
/// - 2025-12-08: 添加目标圆角参数，适配现代手机屏幕圆角
import 'package:flutter/material.dart';

/// 自定义展开路由 - 实现"无缝展开"动画效果
///
/// 核心原理：
/// - 页面从 sourceRect（卡片位置）展开到全屏
/// - 圆角从 sourceRadius 渐变到 targetRadius
/// - 内容全程可见，无淡入淡出
class ExpandingPageRoute<T> extends PageRoute<T> {
  /// 目标页面
  final Widget page;

  /// 源卡片在屏幕上的位置和大小
  final Rect sourceRect;

  /// 源卡片的圆角半径
  final double sourceRadius;

  /// 目标页面的圆角半径（适配现代手机屏幕圆角，默认 32.0）
  final double targetRadius;

  /// 打开动画时长
  final Duration openDuration;

  /// 关闭动画时长
  final Duration closeDuration;

  /// 动画曲线
  final Curve animationCurve;

  ExpandingPageRoute({
    required this.page,
    required this.sourceRect,
    this.sourceRadius = 12.0,
    this.targetRadius = 32.0,
    this.openDuration = const Duration(milliseconds: 400),
    this.closeDuration = const Duration(milliseconds: 350),
    this.animationCurve = Curves.easeInOutCubic,
  });

  @override
  bool get opaque => false; // 透明背景，动画过程可见

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => openDuration;

  @override
  Duration get reverseTransitionDuration => closeDuration;

  /// 禁止底层路由执行 secondaryAnimation（左移动画）
  /// 展开路由本身已完全遮盖底层，不需要底层配合动画
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return page;
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final screenSize = MediaQuery.of(context).size;

    // 使用平滑曲线
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: animationCurve,
      reverseCurve: animationCurve,
    );

    return AnimatedBuilder(
      animation: curvedAnimation,
      builder: (context, _) {
        final progress = curvedAnimation.value;

        // 计算当前矩形：从源位置插值到全屏
        final currentRect = Rect.lerp(
          sourceRect,
          Rect.fromLTWH(0, 0, screenSize.width, screenSize.height),
          progress,
        )!;

        // 计算当前圆角：从卡片圆角渐变到目标圆角
        final currentRadius = sourceRadius + (targetRadius - sourceRadius) * progress;

        // 展开的容器（无遮罩、无阴影、无淡入淡出）
        // Positioned 必须在 Stack 内部使用
        return Stack(
          children: [
            Positioned(
              left: currentRect.left,
              top: currentRect.top,
              width: currentRect.width,
              height: currentRect.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(currentRadius),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Navigator 扩展方法，简化展开路由的使用
extension ExpandingNavigatorExtension on NavigatorState {
  /// 使用展开动画导航到新页面
  /// 
  /// [page] 目标页面
  /// [sourceContext] 源卡片的 BuildContext，用于获取位置
  /// [sourceRadius] 源卡片的圆角，默认 12.0
  /// [openDuration] 打开动画时长
  /// [closeDuration] 关闭动画时长
  Future<T?> pushExpanding<T>({
    required Widget page,
    required BuildContext sourceContext,
    double sourceRadius = 12.0,
    Duration openDuration = const Duration(milliseconds: 400),
    Duration closeDuration = const Duration(milliseconds: 350),
  }) {
    final RenderBox box = sourceContext.findRenderObject() as RenderBox;
    final position = box.localToGlobal(Offset.zero);
    final size = box.size;
    
    return push<T>(
      ExpandingPageRoute(
        page: page,
        sourceRect: Rect.fromLTWH(position.dx, position.dy, size.width, size.height),
        sourceRadius: sourceRadius,
        openDuration: openDuration,
        closeDuration: closeDuration,
      ),
    );
  }
}

/// 从 BuildContext 获取源矩形的辅助函数
Rect getSourceRect(BuildContext context) {
  final RenderBox box = context.findRenderObject() as RenderBox;
  final position = box.localToGlobal(Offset.zero);
  final size = box.size;
  return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
}

