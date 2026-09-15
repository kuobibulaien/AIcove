import 'moe_search_field.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/tokens.dart';

/// Left-pane header; the native traffic lights occupy its leading 96px.
class MacSidebarHeader extends StatelessWidget {
  const MacSidebarHeader({
    super.key,
    required this.title,
    this.onCompose,
    this.onSearchChanged,
    this.searchQuery = '',
  });

  final String title;
  final VoidCallback? onCompose;
  final ValueChanged<String>? onSearchChanged;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    return ColoredBox(
      color: colors.componentBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanStart: (_) => windowManager.startDragging(),
                    child: Center(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                        ),
                      ),
                    ),
                  ),
                ),
                if (onCompose != null)
                  Positioned(
                    right: 8,
                    top: 6,
                    child: IconButton(
                      tooltip: '添加角色',
                      onPressed: onCompose,
                      icon: Icon(
                        Icons.edit_square,
                        size: 23,
                        color: colors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onSearchChanged != null)
            MoeSearchField(
              key: const ValueKey('mac-contact-search'),
              initialValue: searchQuery,
              onChanged: onSearchChanged!,
            ),
        ],
      ),
    );
  }
}
