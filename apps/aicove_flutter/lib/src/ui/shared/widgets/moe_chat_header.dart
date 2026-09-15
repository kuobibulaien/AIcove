import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'moe_floating_surface.dart';
import '../../theme/tokens.dart';

/// Shared floating navigation and actions for phone and desktop chats and
/// pushed detail pages.
class MoeChatHeader extends StatelessWidget implements PreferredSizeWidget {
  const MoeChatHeader({
    super.key,
    required this.title,
    required this.actions,
    required this.showBackButton,
    required this.nativeInset,
    required this.toolbarHeight,
    this.leading,
  });

  final Widget title;
  final List<Widget> actions;
  final bool showBackButton;
  final double nativeInset;
  final double toolbarHeight;

  /// Custom control inside the leading surface; defaults to [BackButton].
  final Widget? leading;

  static double heightFor(TextScaler scaler) =>
      ((scaler.scale(telegramChatHeaderTitleSize) * 1.2).ceilToDouble() +
              (scaler.scale(telegramChatHeaderStatusSize) * 1.2)
                  .ceilToDouble() +
              8)
          .clamp(telegramChatHeaderHeight, double.infinity);

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + telegramChatHeaderVerticalInset * 2);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (Theme.of(context).brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: Colors.transparent),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: telegramChatHeaderVerticalInset,
          ),
          child: SizedBox(
            height: toolbarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (nativeInset > 0) SizedBox(width: nativeInset),
                if (showBackButton) ...[
                  MoeFloatingSurface(
                    radius: toolbarHeight / 2,
                    child: SizedBox.square(
                      dimension: toolbarHeight,
                      child: leading ?? const BackButton(),
                    ),
                  ),
                  const SizedBox(width: telegramChatHeaderGap),
                ],
                Expanded(
                  child: MoeFloatingSurface(
                    radius: toolbarHeight / 2,
                    child: SizedBox(
                      height: toolbarHeight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [Expanded(child: title)],
                        ),
                      ),
                    ),
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: telegramChatHeaderGap),
                  MoeFloatingSurface(
                    radius: toolbarHeight / 2,
                    child: SizedBox(
                      height: toolbarHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: actions,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
