import 'package:flutter/material.dart';
import '../../../../core/theme/tokens.dart';

/// 公共AppBar组件 - 统一应用中所有页面的AppBar样式（应用DRY原则）
class CommonAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool centerTitle;
  final Widget? leading;
  final List<Widget>? actions;

  const CommonAppBar({
    super.key,
    required this.title,
    this.centerTitle = false,
    this.leading,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: moeSurface,
      foregroundColor: moeText,
      elevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(borderWidth),
        child: Container(
          color: moeBorderLight,
          height: borderWidth,
        ),
      ),
      leading: leading,
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: moeText,
        ),
      ),
      centerTitle: centerTitle,
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + borderWidth);
}
