import 'package:flutter/cupertino.dart';

/// Legacy settings entry using the official Cupertino route.
class SettingsDrawerWrapper extends StatefulWidget {
  const SettingsDrawerWrapper({
    super.key,
    required this.child,
    required this.settingsBuilder,
  });
  final Widget child;
  final Widget Function(VoidCallback close) settingsBuilder;

  @override
  State<SettingsDrawerWrapper> createState() => SettingsDrawerWrapperState();
}

class SettingsDrawerWrapperState extends State<SettingsDrawerWrapper> {
  CupertinoPageRoute<void>? _route;

  void open() {
    if (_route?.isActive ?? false) return;
    final route = CupertinoPageRoute<void>(
      builder: (_) => widget.settingsBuilder(close),
    );
    _route = route;
    Navigator.of(context).push(route).whenComplete(() {
      if (identical(_route, route)) _route = null;
    });
  }

  void close() {
    final route = _route;
    if (route != null && route.isCurrent) route.navigator?.maybePop();
  }

  @override
  Widget build(BuildContext context) =>
      SettingsDrawerController(state: this, child: widget.child);
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
