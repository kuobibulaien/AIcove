import 'package:flutter/material.dart';

/// Default blank background shared by the workspace and conversations.
class MoeChatWallpaper extends StatelessWidget {
  const MoeChatWallpaper({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox.expand(child: child),
    );
  }
}
