import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 检测当前是否为桌面平台
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// macOS 风格窗口按钮的尺寸常量
const double kMacButtonSize = 13;
const double kMacButtonSpacing = 8;
const double kMacButtonPadding = 10;

/// macOS 风格窗口按钮占用的总宽度（按钮们 + 左右 padding）
/// 用于其他组件计算需要留出的空间
double get kMacButtonsWidth => isDesktop
    ? kMacButtonPadding +
        (kMacButtonSize * 3) +
        (kMacButtonSpacing * 2) +
        kMacButtonPadding
    : 0;

bool effectiveWindowControlsOnRight(bool configuredOnRight) {
  if (!isDesktop || !Platform.isWindows) {
    return false;
  }
  return configuredOnRight;
}

double macButtonsLeadingInset(bool configuredOnRight) {
  return effectiveWindowControlsOnRight(configuredOnRight)
      ? 0
      : kMacButtonsWidth;
}

double macButtonsTrailingInset(bool configuredOnRight) {
  return effectiveWindowControlsOnRight(configuredOnRight)
      ? kMacButtonsWidth
      : 0;
}

/// 桌面端窗口框架
///
/// 不再使用 Windows 标题栏，而是让 child 填满整个窗口，
/// 仅在左上角叠加 macOS 风格的红黄绿交通灯按钮，
/// 并在顶部提供透明拖拽区域用于移动窗口。
class DesktopWindowFrame extends StatelessWidget {
  final Widget child;
  final bool windowControlsOnRight;

  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.windowControlsOnRight = false,
  });

  @override
  Widget build(BuildContext context) {
    // 非桌面端直接返回 child
    if (!isDesktop) {
      return child;
    }

    final controlsOnRight =
        effectiveWindowControlsOnRight(windowControlsOnRight);

    // Stack：child 填满 → 顶部拖拽条 → macOS 按钮
    return Stack(
      children: [
        // 内容区填满整个窗口（无标题栏偏移）
        Positioned.fill(child: child),
        // 顶部透明拖拽区域（用于拖动窗口 + 双击最大化）
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 40,
          child: _DragArea(),
        ),
        // 窗口控制按钮（macOS 风格排列）
        Positioned(
          top: kMacButtonPadding,
          left: controlsOnRight ? null : kMacButtonPadding,
          right: controlsOnRight ? kMacButtonPadding : null,
          child: const MacWindowButtons(),
        ),
      ],
    );
  }
}

/// 顶部透明拖拽区域
/// 拖拽移动窗口 + 双击最大化/还原
class _DragArea extends StatelessWidget {
  const _DragArea();

  @override
  Widget build(BuildContext context) {
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
      child: const SizedBox.expand(),
    );
  }
}

/// macOS 风格的窗口控制按钮（红黄绿交通灯）
///
/// 可以直接放到 AppBar 的 leading 中，或者通过 Stack 叠加到页面左上角。
/// 当鼠标悬停时显示功能图标（关闭 x / 最小化 - / 最大化 +）。
class MacWindowButtons extends StatefulWidget {
  const MacWindowButtons({super.key});

  @override
  State<MacWindowButtons> createState() => _MacWindowButtonsState();
}

class _MacWindowButtonsState extends State<MacWindowButtons>
    with WindowListener {
  bool _isHovered = false;
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
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 最小化（黄色）— Windows 顺序：最左
          _MacButton(
            color: const Color(0xFFFFBD2E),
            hoverIcon: Icons.remove,
            isHovered: _isHovered,
            onPressed: () => windowManager.minimize(),
          ),
          const SizedBox(width: kMacButtonSpacing),
          // 最大化/还原（绿色）— Windows 顺序：中间
          _MacButton(
            color: const Color(0xFF27C93F),
            hoverIcon: _isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
            isHovered: _isHovered,
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          const SizedBox(width: kMacButtonSpacing),
          // 关闭（红色）— Windows 顺序：最右
          _MacButton(
            color: const Color(0xFFFF5F57),
            hoverIcon: Icons.close,
            isHovered: _isHovered,
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }
}

/// 单个 macOS 风格圆形按钮
class _MacButton extends StatefulWidget {
  final Color color;
  final IconData hoverIcon;
  final bool isHovered;
  final VoidCallback onPressed;

  const _MacButton({
    required this.color,
    required this.hoverIcon,
    required this.isHovered,
    required this.onPressed,
  });

  @override
  State<_MacButton> createState() => _MacButtonState();
}

class _MacButtonState extends State<_MacButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    // 按下时颜色稍微变暗
    final bgColor = _isPressed
        ? Color.lerp(widget.color, Colors.black, 0.15)!
        : widget.color;

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) {
        setState(() => _isPressed = false);
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _isPressed = false),
      child: Container(
        width: kMacButtonSize,
        height: kMacButtonSize,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          // 添加微妙的边框，让按钮更精致
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        alignment: Alignment.center,
        child: widget.isHovered
            ? Icon(
                widget.hoverIcon,
                size: kMacButtonSize - 4,
                color: Colors.black.withValues(alpha: 0.5),
              )
            : null,
      ),
    );
  }
}
