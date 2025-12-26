// 设置覆盖层包装器 - 视差滑动效果
//
// 功能：
// - 点击菜单按钮打开设置面板
// - 设置面板从左侧滑入，主内容向右微移（视差效果）
// - 支持返回手势关闭设置面板
//
// 更新记录：
// - 2025-12-02: 简化为全屏覆盖效果
// - 2025-12-08: 添加视差滑动动画和返回手势支持
import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// 设置覆盖层包装器 - 实现视差滑动效果（从左侧打开）
class SettingsDrawerWrapper extends StatefulWidget {
  final Widget child;
  final Widget Function(VoidCallback close) settingsBuilder;
  final Duration animationDuration;
  /// 主内容位移比例（0-1），如 0.08 表示右移 8%
  final double secondarySlideRatio;

  const SettingsDrawerWrapper({
    super.key,
    required this.child,
    required this.settingsBuilder,
    this.animationDuration = const Duration(milliseconds: 350),
    this.secondarySlideRatio = 0.08,
  });

  @override
  State<SettingsDrawerWrapper> createState() => SettingsDrawerWrapperState();
}

class SettingsDrawerWrapperState extends State<SettingsDrawerWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;      // 设置面板动画
  late Animation<Offset> _secondaryAnimation;  // 主内容视差动画
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.fastOutSlowIn,
    );
    
    // 设置面板：从左侧滑入
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1.0, 0.0),
      end: Offset.zero,
    ).animate(curve);
    
    // 主内容：向右微移（视差效果，与右侧打开的页面方向相反）
    _secondaryAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset(widget.secondarySlideRatio, 0.0),
    ).animate(curve);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void open() {
    if (!_isOpen) {
      setState(() => _isOpen = true);
      _controller.forward();
    }
  }

  void close() {
    if (_isOpen) {
      _controller.reverse().then((_) {
        if (mounted) setState(() => _isOpen = false);
      });
    }
  }

  /// 处理返回手势
  void _handlePopInvoked(bool didPop, dynamic result) {
    if (didPop) return; // 如果已经 pop 了，不做处理
    // 设置面板打开时，关闭设置而不是退出应用
    if (_isOpen) {
      close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;

    return PopScope(
      // 设置面板打开时阻止默认返回行为
      canPop: !_isOpen,
      onPopInvokedWithResult: _handlePopInvoked,
      child: SettingsDrawerController(
        state: this,
        child: Stack(
          children: [
            // 主内容（带视差动画）
            SlideTransition(
              position: _secondaryAnimation,
              child: widget.child,
            ),

            // 设置面板（从左侧滑入，带阴影）
            if (_isOpen)
              Positioned.fill(
                child: SlideTransition(
                  position: _slideAnimation,
                  child: DecoratedBox(
                    // 右侧阴影（与从右侧打开的页面相反）
                    decoration: const BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 16,
                          offset: Offset(4, 0), // 阴影在右侧
                        ),
                      ],
                    ),
                    child: Material(
                      color: colors.surface,
                      child: widget.settingsBuilder(close),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 设置抽屉控制器 - 用于在子组件中控制抽屉
///
/// 使用方法：
/// ```dart
/// // 在需要打开设置的地方
/// SettingsDrawerController.of(context)?.open();
/// ```
class SettingsDrawerController extends InheritedWidget {
  final SettingsDrawerWrapperState state;

  const SettingsDrawerController({
    super.key,
    required this.state,
    required super.child,
  });

  static SettingsDrawerWrapperState? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SettingsDrawerController>()
        ?.state;
  }

  @override
  bool updateShouldNotify(SettingsDrawerController oldWidget) {
    return state != oldWidget.state;
  }
}
