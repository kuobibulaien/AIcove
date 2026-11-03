/// Shared content sheet with a centered navigation bar and an optional footer.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../buttons/moe_button_surface.dart';
import '../moe_floating_surface.dart';

Future<T?> showMoeBottomSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  String? title,
  Widget? titleTrailing,
  Widget? footer,
  bool showDragHandle = true,
  bool showCloseButton = false,
  double? maxHeight,
  bool isScrollControlled = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) => showModalBottomSheet<T>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: isScrollControlled,
  isDismissible: isDismissible,
  // Flutter's built-in sheet drag calls Navigator.pop directly and bypasses
  // PopEntry/MoeAutoSaveScope. MoeBottomSheet handles drag-to-close via
  // Navigator.maybePop so all close paths honor route pop entries.
  enableDrag: false,
  useRootNavigator: useRootNavigator,
  useSafeArea: true,
  showDragHandle: false,
  constraints: const BoxConstraints(maxWidth: 640),
  builder: (context) => MoeBottomSheet(
    title: title,
    titleTrailing: titleTrailing,
    footer: footer,
    showDragHandle: showDragHandle,
    showCloseButton: showCloseButton,
    enableDrag: enableDrag,
    maxHeight: maxHeight,
    child: builder(context),
  ),
);

/// The shell owns safe areas and keyboard avoidance; content uses fixed padding.
/// Scrollable content stays between the navigation bar and the optional footer.
class MoeBottomSheet extends StatefulWidget {
  const MoeBottomSheet({
    super.key,
    required this.child,
    this.title,
    this.titleTrailing,
    this.footer,
    this.showDragHandle = true,
    this.showCloseButton = false,
    this.enableDrag = false,
    this.maxHeight,
  });

  final Widget child;
  final String? title;
  final Widget? titleTrailing;
  final Widget? footer;
  final bool showDragHandle;
  final bool showCloseButton;
  final bool enableDrag;
  final double? maxHeight;

  @override
  State<MoeBottomSheet> createState() => _MoeBottomSheetState();
}

class _MoeBottomSheetState extends State<MoeBottomSheet>
    with SingleTickerProviderStateMixin {
  static const double _kMinFlingVelocity = 700.0;
  static const double _kCloseProgressThreshold = 0.5;

  final GlobalKey _sheetKey = GlobalKey(debugLabel: 'MoeBottomSheet');
  AnimationController? _dragResetController;

  double _dragOffset = 0.0;
  double _resetStartOffset = 0.0;
  bool _closing = false;

  double get _sheetHeight {
    final box = _sheetKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.size.height > 0) {
      return box.size.height;
    }
    return 1.0;
  }

  bool get _canInteract {
    final route = ModalRoute.of(context);
    return !_closing && (route == null || route.isCurrent);
  }

  void _onResetTick() {
    final controller = _dragResetController;
    if (controller == null) return;
    final t = Curves.easeOutCubic.transform(controller.value);
    setState(() {
      _dragOffset = _resetStartOffset * (1.0 - t);
    });
  }

  void _animateBackToZero() {
    if (!mounted || _dragOffset <= 0.0) return;
    _resetStartOffset = _dragOffset;
    final controller = _dragResetController ??= AnimationController(
      vsync: this,
      duration: kAnimFast,
    )..addListener(_onResetTick);
    controller.forward(from: 0.0);
  }

  void _handleDragStart(DragStartDetails details) {
    if (!_canInteract) return;
    _dragResetController?.stop();
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_canInteract) return;
    final next = math.max(0.0, _dragOffset + (details.primaryDelta ?? 0.0));
    if (next == _dragOffset) return;
    setState(() {
      _dragOffset = next;
    });
  }

  Future<void> _handleDragEnd(DragEndDetails details) async {
    if (!_canInteract) return;
    final velocityY = details.velocity.pixelsPerSecond.dy;
    final height = _sheetHeight;
    final shouldClose =
        velocityY > _kMinFlingVelocity ||
        (_dragOffset / height) > (1.0 - _kCloseProgressThreshold);

    if (!shouldClose) {
      _animateBackToZero();
      return;
    }

    _closing = true;
    final route = ModalRoute.of(context);
    try {
      await Navigator.maybePop(context);
    } finally {
      _closing = false;
      if (mounted && (route == null || route.isActive)) {
        _animateBackToZero();
      }
    }
  }

  @override
  void dispose() {
    _dragResetController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final media = MediaQuery.of(context);
    final hasNavigation =
        widget.title != null ||
        widget.showCloseButton ||
        widget.titleTrailing != null;
    final navigationHeight = math.max(52.0, media.textScaler.scale(20) + 24);

    Widget sheet = ConstrainedBox(
      key: _sheetKey,
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: math.min(
          widget.maxHeight ?? media.size.height * 0.85,
          math.max(0, media.size.height - media.padding.top - 12),
        ),
      ),
      child: MoeFloatingSurface(
        baseline: MoeMaterialBaseline.background,
        radius: 28,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: BorderSide.none,
        child: MoeSurfaceGroup(
          child: SafeArea(
            top: false,
            child: AnimatedPadding(
              duration: kAnimFast,
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.showDragHandle)
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 8, bottom: 4),
                        width: 36,
                        height: 5,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: colors.text.withValues(alpha: 0.16),
                        ),
                      ),
                    ),
                  if (hasNavigation)
                    SizedBox(
                      height: navigationHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final sideWidth = widget.titleTrailing != null
                                ? math.min(104.0, constraints.maxWidth * 0.3)
                                : (widget.showCloseButton ? 44.0 : 0.0);
                            return NavigationToolbar(
                              centerMiddle: true,
                              middleSpacing: 8,
                              leading: SizedBox(
                                width: sideWidth,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: widget.showCloseButton
                                      ? Tooltip(
                                          message: '关闭',
                                          child: CupertinoButton(
                                            padding: const EdgeInsets.all(6),
                                            minimumSize: const Size(44, 44),
                                            onPressed: () =>
                                                Navigator.maybePop(context),
                                            child: MoeButtonSurface(
                                              shareParentSurface: false,
                                              width: 32,
                                              height: 32,
                                              radius: 999,
                                              child: Icon(
                                                CupertinoIcons.xmark,
                                                size: 16,
                                                color: colors.textSecondary,
                                              ),
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                              ),
                              middle: widget.title == null
                                  ? null
                                  : Semantics(
                                      header: true,
                                      child: Text(
                                        widget.title!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600,
                                          color: colors.text,
                                        ),
                                      ),
                                    ),
                              trailing: SizedBox(
                                width: sideWidth,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: widget.titleTrailing,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  Flexible(child: widget.child),
                  if (widget.footer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: widget.footer!,
                    )
                  else
                    const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (_dragOffset > 0.0) {
      sheet = Transform.translate(
        offset: Offset(0.0, _dragOffset),
        child: sheet,
      );
    }

    if (widget.enableDrag) {
      sheet = RawGestureDetector(
        excludeFromSemantics: true,
        gestures: <Type, GestureRecognizerFactory<GestureRecognizer>>{
          VerticalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                VerticalDragGestureRecognizer
              >(() => VerticalDragGestureRecognizer(debugOwner: this), (
                VerticalDragGestureRecognizer instance,
              ) {
                instance
                  ..onStart = _handleDragStart
                  ..onUpdate = _handleDragUpdate
                  ..onEnd = _handleDragEnd
                  ..onlyAcceptDragOnThreshold = true;
              }),
        },
        child: sheet,
      );
    }

    return sheet;
  }
}
