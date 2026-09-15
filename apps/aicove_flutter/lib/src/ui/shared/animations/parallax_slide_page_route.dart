import 'package:flutter/cupertino.dart';
import '../widgets/moe_adaptive_shell.dart';

/// Workspace adapter. All animation, timing and gestures belong to Flutter.
/// The legacy name is retained for existing navigation call sites.
class ParallaxSlidePageRoute<T> extends CupertinoPageRoute<T>
    with MoeWorkspaceRouteTransition<T> {
  final bool dimPreviousPage;

  @override
  Color? get barrierColor => dimPreviousPage && !_isWideWorkspace(navigator)
      ? super.barrierColor
      : null;

  ParallaxSlidePageRoute({required Widget page, this.dimPreviousPage = true})
    : super(builder: (_) => page);
}

/// Cupertino page with the workspace background policy and live Page settings.
class ParallaxSlidePage<T> extends CupertinoPage<T> {
  const ParallaxSlidePage({
    required super.child,
    this.dimPreviousPage = true,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
    super.canPop,
    super.onPopInvoked,
    super.maintainState,
    super.title,
    super.fullscreenDialog,
    super.allowSnapshotting,
  });

  /// Shared desktop backgrounds remain visible through transparent chat pages.
  final bool dimPreviousPage;

  @override
  Route<T> createRoute(BuildContext context) => _ParallaxPageRoute<T>(this);
}

class _ParallaxPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T>, MoeWorkspaceRouteTransition<T> {
  _ParallaxPageRoute(ParallaxSlidePage<T> page)
    : super(settings: page, allowSnapshotting: page.allowSnapshotting);

  ParallaxSlidePage<T> get _page => settings as ParallaxSlidePage<T>;
  @override
  Color? get barrierColor =>
      _page.dimPreviousPage && !_isWideWorkspace(navigator)
      ? super.barrierColor
      : null;
  @override
  Widget buildContent(BuildContext context) => _page.child;
  @override
  String? get title => _page.title;
  @override
  bool get maintainState => _page.maintainState;
  @override
  bool get fullscreenDialog => _page.fullscreenDialog;
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      fullscreenDialog ? null : CupertinoPageTransition.delegatedTransition;
}

/// Lets the shared workspace finish sibling transitions in the same frame.
mixin MoeWorkspaceRouteTransition<T> on PageRoute<T> {
  void finishWorkspaceTransition({required bool entering}) {
    controller?.value = entering ? 1 : 0;
  }
}

extension ParallaxSlideNavigatorExtension on NavigatorState {
  Future<T?> pushParallaxSlide<T>({required Widget page}) =>
      push<T>(ParallaxSlidePageRoute<T>(page: page));
}

bool _isWideWorkspace(NavigatorState? navigator) =>
    navigator != null &&
    MoeWorkspace.maybeOf(navigator.context)?.isWide == true;
