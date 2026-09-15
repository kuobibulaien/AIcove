import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/tokens.dart';
import 'desktop_window_frame.dart';
import 'moe_adaptive_shell.dart';
import 'moe_chat_header.dart';
import 'moe_floating_surface.dart';

/// Shared Telegram-style header with pane-aware native window controls.
class MoeAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool showBackButton;
  final Widget? leading;
  final double? leadingWidth;
  final List<Widget>? actions;
  final bool centerTitle;
  final double titleLeftPadding;

  const MoeAppBar({
    super.key,
    required this.title,
    this.showBackButton = false,
    this.leading,
    this.leadingWidth,
    this.actions,
    this.centerTitle = false,
    this.titleLeftPadding = 20,
  });

  /// Pushed pages share the chat header's floating pills; root pages keep the
  /// flat bar.
  bool get _floating => showBackButton || leading != null;

  @override
  Size get preferredSize => Size.fromHeight(
    _floating
        ? telegramChatHeaderHeight + telegramChatHeaderVerticalInset * 2
        : kToolbarHeight + borderWidth,
  );

  @override
  Widget build(BuildContext context) {
    final changes = MoeWorkspace.navigationChangesOf(context);
    return changes == null
        ? _buildBar(context)
        : ValueListenableBuilder<int>(
            valueListenable: changes,
            builder: (context, _, _) => _buildBar(context),
          );
  }

  Widget _buildBar(BuildContext context) {
    final colors = context.moeColors;
    final workspace = MoeWorkspace.maybeOf(context);
    final immersive = workspace?.isWide == true && workspace?.isDetail == true;
    final effectiveBackButton =
        showBackButton && MoeWorkspace.showsBackButton(context);
    final effectiveLeading = showBackButton && !effectiveBackButton
        ? null
        : leading;
    final hasLeading = effectiveLeading != null || effectiveBackButton;
    final nativeInset =
        isDesktop &&
            Platform.isMacOS &&
            MoeWorkspace.ownsWindowControls(context)
        ? 88.0
        : 0.0;
    if (_floating) {
      return MoeChatHeader(
        showBackButton: hasLeading,
        leading: effectiveLeading,
        nativeInset: nativeInset,
        toolbarHeight: telegramChatHeaderHeight,
        title: Padding(
          padding: EdgeInsets.only(left: centerTitle ? 0 : 8),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: centerTitle ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colors.headerContentColor,
            ),
          ),
        ),
        actions: actions ?? const [],
      );
    }
    final control =
        effectiveLeading ??
        (effectiveBackButton ? const BackButton() : const SizedBox.shrink());
    return AppBar(
      backgroundColor: Colors.transparent,
      flexibleSpace: immersive || MoeSurfaceGroup.contains(context)
          ? null
          : MoeFloatingSurface(
              radius: 0,
              shadows: const [],
              border: BorderSide.none,
              solidColor: colors.headerColor,
              child: const SizedBox.expand(),
            ),
      foregroundColor: colors.headerContentColor,
      systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 0,
      leadingWidth: nativeInset + (hasLeading ? leadingWidth ?? 48 : 0),
      leading: Padding(
        padding: EdgeInsets.only(left: nativeInset),
        child: control,
      ),
      automaticallyImplyLeading: false,
      title: Padding(
        padding: EdgeInsets.only(
          left: centerTitle || hasLeading ? 0 : titleLeftPadding,
        ),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: colors.headerContentColor,
          ),
        ),
      ),
      centerTitle: centerTitle,
      actions: actions,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(borderWidth),
        child: Container(
          height: borderWidth,
          color: immersive ? Colors.transparent : colors.divider,
        ),
      ),
    );
  }
}

class MoeDetailAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  const MoeDetailAppBar({super.key, required this.title, this.actions});
  @override
  Size get preferredSize => const Size.fromHeight(
    telegramChatHeaderHeight + telegramChatHeaderVerticalInset * 2,
  );
  @override
  Widget build(BuildContext context) =>
      MoeAppBar(title: title, showBackButton: true, actions: actions);
}
