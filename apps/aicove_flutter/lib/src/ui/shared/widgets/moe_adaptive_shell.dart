import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/tokens.dart';
import '../animations/parallax_slide_page_route.dart';
import 'desktop_window_frame.dart';
import 'moe_chat_wallpaper.dart';

/// The detail navigator stays mounted when the window crosses the breakpoint.
class MoeDetailStackObserver extends NavigatorObserver {
  final hasDetail = ValueNotifier<bool>(false);
  final routeCount = ValueNotifier<int>(0);
  final background = ValueNotifier<Widget?>(null);
  final List<Route<dynamic>> _routes = [];
  final List<Route<dynamic>> _visibleRoutes = [];
  final Map<Route<dynamic>, Widget> _backgrounds = {};
  int _exiting = 0;
  bool _scheduled = false;
  bool _disposed = false;

  bool get hasProtectedRoute => _routes.any(
    (route) => route.popDisposition == RoutePopDisposition.doNotPop,
  );

  void _changed() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) {
        routeCount.value = _routes.length;
        hasDetail.value = _routes.length > 1 || _exiting > 0;
        final page = _visibleRoutes.whereType<PageRoute<dynamic>>().lastOrNull;
        background.value = _backgrounds[page];
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _visibleRoutes.add(route);
    if (_routes.length == 2 &&
        navigator != null &&
        MoeWorkspace.maybeOf(navigator!.context)?.isWide == true &&
        route is MoeWorkspaceRouteTransition) {
      route.finishWorkspaceTransition(entering: true);
    }
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    if (route is TransitionRoute<dynamic>) {
      _exiting++;
      route.completed.whenComplete(() {
        _exiting--;
        _forgetBackground(route);
        _changed();
      });
    } else {
      _forgetBackground(route);
    }
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _forgetBackground(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final visibleIndex = oldRoute == null
        ? -1
        : _visibleRoutes.indexOf(oldRoute);
    if (visibleIndex >= 0) {
      if (newRoute == null) {
        _visibleRoutes.removeAt(visibleIndex);
      } else {
        _visibleRoutes[visibleIndex] = newRoute;
      }
    }
    _backgrounds.remove(oldRoute);
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _changed();
  }

  void dispose() {
    _disposed = true;
    hasDetail.dispose();
    routeCount.dispose();
    background.dispose();
    _backgrounds.clear();
    _visibleRoutes.clear();
  }

  void _forgetBackground(Route<dynamic> route) {
    _visibleRoutes.remove(route);
    _backgrounds.remove(route);
  }

  void setBackground(Route<dynamic> route, Widget value) {
    if (_disposed ||
        !_visibleRoutes.contains(route) ||
        identical(_backgrounds[route], value)) {
      return;
    }
    _backgrounds[route] = value;
    _changed();
  }
}

/// Paint page backgrounds once across the workspace, underneath the phone pane.
/// On a narrow screen the same background stays local to the page.
class MoeWorkspaceBackground extends StatefulWidget {
  const MoeWorkspaceBackground({
    super.key,
    required this.background,
    required this.child,
  });
  final Widget background;
  final Widget child;

  @override
  State<MoeWorkspaceBackground> createState() => _MoeWorkspaceBackgroundState();
}

class _MoeWorkspaceBackgroundState extends State<MoeWorkspaceBackground> {
  void _register() {
    final scope = MoeWorkspace.maybeOf(context);
    final route = ModalRoute.of(context);
    if (scope == null || !scope.isDetail || route == null) return;
    final observer = scope.navigatorKey.currentState?.widget.observers
        .whereType<MoeDetailStackObserver>()
        .firstOrNull;
    observer?.setBackground(route, widget.background);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(MoeWorkspaceBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  @override
  Widget build(BuildContext context) {
    final scope = MoeWorkspace.maybeOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (scope == null || !scope.isWide || !scope.isDetail)
          Positioned.fill(child: IgnorePointer(child: widget.background)),
        KeyedSubtree(
          key: const ValueKey('workspace-background-content'),
          child: widget.child,
        ),
      ],
    );
  }
}

/// Android predictive back only reaches Flutter while the framework claims it.
/// A root dialog closing reports the root navigator alone, so merge the nested
/// detail stack before telling the platform; otherwise back leaves the app.
NotificationListenerCallback<NavigationNotification> moeNavigationNotification(
  GoRouter router,
) {
  return (notification) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.detached) {
      return true;
    }
    SystemNavigator.setFrameworkHandlesBack(
      notification.canHandlePop || router.canPop(),
    );
    return true;
  };
}

/// Routes opened from a primary page enter the same navigator as chat details.
/// Descendants of a detail page keep using Navigator.of(context) normally.
class MoeWorkspace extends InheritedWidget {
  const MoeWorkspace({
    super.key,
    required this.navigatorKey,
    required this.isWide,
    required this.isDetail,
    required super.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final bool isWide;
  final bool isDetail;

  static MoeWorkspace? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoeWorkspace>();

  static NavigatorState navigatorOf(BuildContext context) =>
      maybeOf(context)?.navigatorKey.currentState ?? Navigator.of(context);

  static MoeDetailStackObserver? _observer(NavigatorState navigator) =>
      navigator.widget.observers
          .whereType<MoeDetailStackObserver>()
          .firstOrNull;

  static ValueNotifier<int>? navigationChangesOf(BuildContext context) {
    final navigator = maybeOf(context)?.navigatorKey.currentState;
    return navigator == null ? null : _observer(navigator)?.routeCount;
  }

  static bool _replacesDetail(BuildContext context) {
    final scope = maybeOf(context);
    return scope != null && scope.isWide && !scope.isDetail;
  }

  static bool _canReplace(BuildContext context, NavigatorState navigator) {
    if (!(_observer(navigator)?.hasProtectedRoute ?? false)) return true;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('请先完成或退出右侧正在编辑的页面，再切换。')));
    return false;
  }

  static void _clearDetail(NavigatorState navigator) {
    navigator.popUntil((route) {
      if (route.isFirst) return true;
      if (route is MoeWorkspaceRouteTransition) {
        route.finishWorkspaceTransition(entering: false);
      }
      return false;
    });
  }

  static Future<T?> open<T>(BuildContext context, Widget page) {
    final navigator = navigatorOf(context);
    final replace = _replacesDetail(context);
    if (replace && !_canReplace(context, navigator)) return Future.value();
    final route = ParallaxSlidePageRoute<T>(
      page: page,
      dimPreviousPage: !(maybeOf(context)?.isWide ?? false),
    );
    // Pop page-backed routes so go_router also updates its location. Removing
    // them directly leaves a stale chat match that can resurrect on next push.
    if (replace) _clearDetail(navigator);
    return navigator.push<T>(route);
  }

  /// The placeholder is followed by one secondary page, then its descendants.
  static bool showsBackButton(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null || !scope.isWide || !scope.isDetail) return true;
    final route = ModalRoute.of(context);
    final navigator = scope.navigatorKey.currentState;
    if (navigator == null || route == null) return true;
    final routes = _observer(navigator)?._routes;
    return routes == null || routes.indexOf(route) > 1;
  }

  /// Selecting another chat must not discard an editor protected by PopScope.
  static void openLocation(
    BuildContext context,
    String location, {
    Object? extra,
  }) {
    final navigator = navigatorOf(context);
    if (_replacesDetail(context)) {
      if (!_canReplace(context, navigator)) return;
      _clearDetail(navigator);
      context.go(location, extra: extra);
    } else {
      context.push(location, extra: extra);
    }
  }

  /// macOS traffic lights belong to the pane at the window's leading edge.
  static bool ownsWindowControls(BuildContext context) {
    final scope = maybeOf(context);
    if (scope != null && isDesktop && !scope.isWide) return false;
    return scope == null || !scope.isWide || !scope.isDetail;
  }

  @override
  bool updateShouldNotify(MoeWorkspace oldWidget) =>
      oldWidget.isWide != isWide ||
      oldWidget.isDetail != isDetail ||
      oldWidget.navigatorKey != navigatorKey;
}

class MoeAdaptiveShell extends StatefulWidget {
  const MoeAdaptiveShell({
    super.key,
    required this.primary,
    required this.detail,
    required this.navigatorKey,
    required this.observer,
  });

  final Widget primary;
  final Widget detail;
  final GlobalKey<NavigatorState> navigatorKey;
  final MoeDetailStackObserver observer;

  @override
  State<MoeAdaptiveShell> createState() => _MoeAdaptiveShellState();
}

class _MoeAdaptiveShellState extends State<MoeAdaptiveShell> {
  double _primaryWidth = telegramPrimaryWidth;
  double? _windowControlsInset;

  void _alignWindowControls(double inset) {
    if (!isDesktop || !Platform.isMacOS || _windowControlsInset == inset) {
      return;
    }
    _windowControlsInset = inset;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await const MethodChannel(
          'aicove/window_chrome',
        ).invokeMethod<void>('alignTrafficLights', {'inset': inset});
      } on MissingPluginException {
        // Widget tests do not attach a native window.
      }
    });
  }

  Widget _pane({
    required Widget child,
    required bool isWide,
    required bool isDetail,
    required double width,
    required double height,
  }) {
    final media = MediaQuery.of(context);
    return MoeWorkspace(
      navigatorKey: widget.navigatorKey,
      isWide: isWide,
      isDetail: isDetail,
      child: MediaQuery(
        data: media.copyWith(
          size: Size(width, height),
          padding: isWide
              ? media.padding.copyWith(
                  left: isDetail ? 0 : media.padding.left,
                  right: isDetail ? media.padding.right : 0,
                  // Floating detail headers align with the primary panel's top edge.
                  top: isDetail
                      ? media.padding.top +
                            telegramWorkspaceInset -
                            telegramChatHeaderVerticalInset
                      : media.padding.top,
                )
              : media.padding,
        ),
        child: ClipRect(child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width >= layoutBreakpoint;
        final inset = isWide ? telegramWorkspaceInset : 0.0;
        final titleBarHeight = isDesktop && !isWide
            ? telegramCompactTitleBarHeight
            : 0.0;
        final contentHeight = constraints.maxHeight - titleBarHeight;
        _alignWindowControls(inset);
        final maxPrimary = math.min(
          telegramPrimaryMaxWidth,
          width - telegramDetailMinWidth - inset * 2,
        );
        final primaryWidth = isWide
            ? _primaryWidth
                  .clamp(telegramPrimaryMinWidth, maxPrimary)
                  .toDouble()
            : width;
        final detailLeft = isWide ? primaryWidth + inset * 2 : 0.0;
        final radius = BorderRadius.circular(
          isWide ? telegramPrimaryRadius : 0,
        );
        return ValueListenableBuilder<bool>(
          valueListenable: widget.observer.hasDetail,
          builder: (context, hasDetail, _) {
            final primaryPane = Positioned(
              key: const ValueKey('workspace-primary'),
              left: inset,
              top: titleBarHeight + inset,
              bottom: inset,
              width: primaryWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: isWide
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? 0.22
                                  : 0.10,
                            ),
                            blurRadius: 32,
                            offset: const Offset(4, 8),
                          ),
                        ]
                      : const [],
                ),
                child: ClipRRect(
                  key: const ValueKey('workspace-primary-surface'),
                  borderRadius: radius,
                  child: IgnorePointer(
                    ignoring: !isWide && hasDetail,
                    child: ExcludeSemantics(
                      excluding: !isWide && hasDetail,
                      child: TickerMode(
                        enabled: isWide || !hasDetail,
                        child: _pane(
                          child: widget.primary,
                          isWide: isWide,
                          isDetail: false,
                          width: primaryWidth,
                          height: contentHeight - inset * 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final detailPane = Positioned(
              key: const ValueKey('workspace-detail'),
              left: detailLeft,
              top: titleBarHeight,
              right: 0,
              bottom: 0,
              child: Offstage(
                offstage: !isWide && !hasDetail,
                child: _pane(
                  child: widget.detail,
                  isWide: isWide,
                  isDetail: true,
                  width: width - detailLeft,
                  height: contentHeight,
                ),
              ),
            );
            return CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  widget.navigatorKey.currentState?.maybePop();
                },
              },
              child: Focus(
                autofocus: true,
                child: ColoredBox(
                  color: context.moeColors.surfaceAlt,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        key: const ValueKey('workspace-background'),
                        top: titleBarHeight,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<Widget?>(
                            valueListenable: widget.observer.background,
                            builder: (_, background, __) => isWide
                                ? background ?? const SizedBox.expand()
                                : const SizedBox.expand(),
                          ),
                        ),
                      ),
                      // Stable keys keep both pane trees alive when their paint order changes.
                      if (isWide) ...[
                        detailPane,
                        primaryPane,
                      ] else ...[
                        primaryPane,
                        detailPane,
                      ],
                      if (titleBarHeight > 0)
                        Positioned(
                          key: const ValueKey('workspace-compact-titlebar'),
                          top: 0,
                          left: 0,
                          right: 0,
                          height: titleBarHeight,
                          child: Material(
                            color: context.moeColors.headerColor,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (_) => windowManager.startDragging(),
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  left: 104,
                                  right: 12,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'AIcove',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          context.moeColors.headerContentColor,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (isWide)
                        Positioned(
                          left: primaryWidth + inset + 2,
                          top: inset + telegramPrimaryRadius,
                          bottom: inset + telegramPrimaryRadius,
                          width: 8,
                          child: Semantics(
                            container: true,
                            label: '调整左栏宽度',
                            child: MouseRegion(
                              cursor: SystemMouseCursors.resizeColumn,
                              child: GestureDetector(
                                key: const ValueKey('workspace-resize-handle'),
                                behavior: HitTestBehavior.opaque,
                                dragStartBehavior: DragStartBehavior.down,
                                onDoubleTap: () => setState(
                                  () => _primaryWidth = telegramPrimaryWidth,
                                ),
                                onHorizontalDragStart: (_) =>
                                    _primaryWidth = primaryWidth,
                                onHorizontalDragUpdate: (event) => setState(() {
                                  _primaryWidth =
                                      (_primaryWidth + event.delta.dx)
                                          .clamp(
                                            telegramPrimaryMinWidth,
                                            maxPrimary,
                                          )
                                          .toDouble();
                                }),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Shared empty detail surface; no implicit selection or background chat page.
class MoeWorkspacePlaceholder extends StatelessWidget {
  const MoeWorkspacePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    if (MoeWorkspace.maybeOf(context)?.isWide == false) {
      return const SizedBox.expand();
    }
    return Material(
      color: Colors.transparent,
      child: MoeWorkspaceBackground(
        background: const MoeChatWallpaper(
          slot: GlobalWallpaperSlot.empty,
          child: SizedBox.expand(),
        ),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            decoration: BoxDecoration(
              color: colors.text.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Text(
              '选择一个聊天，开始对话',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}
