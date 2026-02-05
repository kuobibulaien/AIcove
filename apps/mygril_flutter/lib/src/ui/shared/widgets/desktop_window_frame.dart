import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 检测当前是否为桌面平台
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 桌面端窗口框架
/// 为 Windows/macOS/Linux 提供自定义标题栏（拖拽移动 + 窗口控制按钮）
/// 移动端和 Web 端直接返回 child，不做任何处理
class DesktopWindowFrame extends StatelessWidget {
  final Widget child;

  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // 非桌面端直接返回 child
    if (!isDesktop) {
      return child;
    }

    return Column(
      children: [
        const DesktopTitleBar(),
        Expanded(child: child),
      ],
    );
  }
}

/// 自定义标题栏（简洁风格，类似 Telegram/微信）
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _updateMaximizedState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _updateMaximizedState() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void onWindowMaximize() {
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // 标题栏透明，让 Mica 云母效果显示出来
    const bgColor = Colors.transparent;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: Container(
        height: 32,
        color: bgColor,
        child: Row(
          children: [
            // 左侧留白（与下方内容对齐）
            const Expanded(child: SizedBox.shrink()),
            // 窗口控制按钮（右侧）
            _WindowButton(
              icon: Icons.horizontal_rule_rounded,
              onPressed: () => windowManager.minimize(),
              isDark: isDark,
            ),
            _WindowButton(
              icon: _isMaximized
                  ? Icons.filter_none_rounded
                  : Icons.check_box_outline_blank_rounded,
              iconSize: _isMaximized ? 12 : 14,
              onPressed: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              isDark: isDark,
            ),
            _WindowButton(
              icon: Icons.close_rounded,
              onPressed: () => windowManager.close(),
              isDark: isDark,
              isClose: true,
            ),
          ],
        ),
      ),
    );
  }
}

/// 窗口控制按钮（简洁风格）
class _WindowButton extends StatefulWidget {
  final IconData icon;
  final double iconSize;
  final VoidCallback onPressed;
  final bool isDark;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    this.iconSize = 16,
    required this.onPressed,
    required this.isDark,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // 悬停时：关闭按钮变红，其他按钮微微变暗/亮
    final hoverColor = widget.isClose
        ? const Color(0xFFE81123)
        : (widget.isDark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.06));
    // 图标颜色：根据主题使用深色或浅色
    final iconColor = widget.isDark ? Colors.white : Colors.black87;
    // 关闭按钮悬停时图标变白
    final actualIconColor = (widget.isClose && _isHovered) ? Colors.white : iconColor;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 32,
          color: _isHovered ? hoverColor : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: widget.iconSize,
            color: actualIconColor,
          ),
        ),
      ),
    );
  }
}
