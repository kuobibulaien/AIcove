/// Shared content sheet with a centered navigation bar and an optional footer.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import '../buttons/moe_button_surface.dart';
import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
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
  enableDrag: enableDrag,
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
    maxHeight: maxHeight,
    child: builder(context),
  ),
);

/// The shell owns safe areas and keyboard avoidance; content uses fixed padding.
/// Scrollable content stays between the navigation bar and the optional footer.
class MoeBottomSheet extends StatelessWidget {
  const MoeBottomSheet({
    super.key,
    required this.child,
    this.title,
    this.titleTrailing,
    this.footer,
    this.showDragHandle = true,
    this.showCloseButton = false,
    this.maxHeight,
  });

  final Widget child;
  final String? title;
  final Widget? titleTrailing;
  final Widget? footer;
  final bool showDragHandle;
  final bool showCloseButton;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final media = MediaQuery.of(context);
    final hasNavigation =
        title != null || showCloseButton || titleTrailing != null;
    final navigationHeight = math.max(52.0, media.textScaler.scale(20) + 24);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 640,
        maxHeight: math.min(
          maxHeight ?? media.size.height * 0.85,
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
                  if (showDragHandle)
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
                            final sideWidth = titleTrailing != null
                                ? math.min(104.0, constraints.maxWidth * 0.3)
                                : (showCloseButton ? 44.0 : 0.0);
                            return NavigationToolbar(
                              centerMiddle: true,
                              middleSpacing: 8,
                              leading: SizedBox(
                                width: sideWidth,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: showCloseButton
                                      ? Tooltip(
                                          message: '关闭',
                                          child: CupertinoButton(
                                            padding: const EdgeInsets.all(6),
                                            minimumSize: const Size(44, 44),
                                            onPressed: () =>
                                                Navigator.maybePop(context),
                                            child: MoeButtonSurface(
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
                              middle: title == null
                                  ? null
                                  : Semantics(
                                      header: true,
                                      child: Text(
                                        title!,
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
                                  child: titleTrailing,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  Flexible(child: child),
                  if (footer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      child: footer!,
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
  }
}
