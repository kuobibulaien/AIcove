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

  /// Wide detail pages are transparent, so the page being covered would show
  /// through the incoming page and vanish mid-parallax when it goes offstage.
  /// Clip it at the incoming page's leading edge, as an opaque page would.
  /// The wrapper stays in narrow mode so crossing the breakpoint keeps state.
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final transition = super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
    return _CoveredPageClip(
      animation: secondaryAnimation,
      enabled: _isWideWorkspace(navigator),
      linear: navigator?.userGestureInProgress ?? false,
      child: transition,
    );
  }
}

/// Tracks the incoming Cupertino page's position curve.
class _CoveredPageClip extends StatefulWidget {
  const _CoveredPageClip({
    required this.animation,
    required this.enabled,
    required this.linear,
    required this.child,
  });

  final Animation<double> animation;
  final bool enabled;
  final bool linear;
  final Widget child;

  @override
  State<_CoveredPageClip> createState() => _CoveredPageClipState();
}

class _CoveredPageClipState extends State<_CoveredPageClip> {
  CurvedAnimation? _curve;

  Animation<double> get _covered => _curve ?? widget.animation;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  @override
  void didUpdateWidget(_CoveredPageClip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.linear != widget.linear) {
      _curve?.dispose();
      _setup();
    }
  }

  void _setup() {
    _curve = widget.linear
        ? null
        : CurvedAnimation(
            parent: widget.animation,
            curve: Curves.fastEaseInToSlowEaseOut,
            reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
          );
  }

  @override
  void dispose() {
    _curve?.dispose();
    super.dispose();
  }

  @override
  // Rebuilt every frame by the route; unclipped while uncovered so the
  // page's own edge shadow survives.
  Widget build(BuildContext context) => ClipRect(
    clipBehavior: widget.enabled && _covered.value > 0
        ? Clip.hardEdge
        : Clip.none,
    clipper: _CoveredPageClipper(_covered, Directionality.of(context)),
    child: widget.child,
  );
}

class _CoveredPageClipper extends CustomClipper<Rect> {
  _CoveredPageClipper(this.covered, this.direction) : super(reclip: covered);

  final Animation<double> covered;
  final TextDirection direction;

  @override
  Rect getClip(Size size) {
    final visible = size.width * (1 - covered.value.clamp(0.0, 1.0));
    return direction == TextDirection.rtl
        ? Rect.fromLTRB(size.width - visible, 0, size.width, size.height)
        : Rect.fromLTRB(0, 0, visible, size.height);
  }

  @override
  bool shouldReclip(_CoveredPageClipper oldClipper) =>
      oldClipper.covered != covered || oldClipper.direction != direction;
}

extension ParallaxSlideNavigatorExtension on NavigatorState {
  Future<T?> pushParallaxSlide<T>({required Widget page}) =>
      push<T>(ParallaxSlidePageRoute<T>(page: page));
}

bool _isWideWorkspace(NavigatorState? navigator) =>
    navigator != null &&
    MoeWorkspace.maybeOf(navigator.context)?.isWide == true;
