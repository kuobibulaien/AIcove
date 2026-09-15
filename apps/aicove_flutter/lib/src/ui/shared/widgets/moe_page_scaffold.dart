import 'package:flutter/material.dart';

import 'moe_adaptive_shell.dart';

/// Shared page surface. The detail route owns its background across the whole
/// workspace; its controls and Scaffold remain inside the detail pane.
class MoePageScaffold extends StatelessWidget {
  const MoePageScaffold({
    super.key,
    this.appBar,
    this.body,
    this.backgroundColor,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset,
    this.extendBody = false,
    this.extendBodyBehindAppBar = false,
  });

  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Color? backgroundColor;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final bool? resizeToAvoidBottomInset;
  final bool extendBody;
  final bool extendBodyBehindAppBar;

  @override
  Widget build(BuildContext context) {
    final color = backgroundColor ?? Theme.of(context).scaffoldBackgroundColor;
    return MoeWorkspaceBackground(
      background: ColoredBox(color: color),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: appBar,
        body: body,
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        extendBody: extendBody,
        extendBodyBehindAppBar: extendBodyBehindAppBar,
      ),
    );
  }
}
