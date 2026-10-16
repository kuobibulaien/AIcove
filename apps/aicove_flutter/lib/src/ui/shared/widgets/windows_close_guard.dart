import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/app_logger.dart';
import '../../../features/settings/app_settings.dart';
import '../../theme/tokens.dart';
import 'meotalk_dialog.dart';

const _trayIconAsset = 'assets/icons/tray/app_icon.ico';
const _menuShowKey = 'show';
const _menuExitKey = 'exit';

/// Keeps the Windows process alive in the system tray when the window closes.
///
/// Proactive replies run on in-process timers, so a full exit stops them. The
/// first close asks whether to exit or keep running in the tray and remembers
/// the answer; it can be changed later in the UI settings page.
class WindowsCloseGuard extends ConsumerStatefulWidget {
  final Widget child;

  const WindowsCloseGuard({super.key, required this.child});

  @override
  ConsumerState<WindowsCloseGuard> createState() => _WindowsCloseGuardState();
}

class _WindowsCloseGuardState extends ConsumerState<WindowsCloseGuard>
    with WindowListener, TrayListener {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_setUp());
  }

  Future<void> _setUp() async {
    try {
      await windowManager.setPreventClose(true);
      await trayManager.setIcon(_trayIconAsset);
      await trayManager.setToolTip('AIcove');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: _menuShowKey, label: '显示 AIcove'),
            MenuItem.separator(),
            MenuItem(key: _menuExitKey, label: '退出'),
          ],
        ),
      );
    } catch (error) {
      AppLogger.warning('WindowsCloseGuard', 'Tray setup failed: $error');
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      var behavior =
          ref.read(appSettingsProvider).valueOrNull?.windowsCloseBehavior ??
          WindowsCloseBehavior.ask;
      if (behavior == WindowsCloseBehavior.ask) {
        final choice = await _askCloseBehavior();
        if (choice == null) return;
        behavior = choice;
        await ref
            .read(appSettingsProvider.notifier)
            .setWindowsCloseBehavior(choice);
      }
      if (behavior == WindowsCloseBehavior.tray) {
        await windowManager.hide();
      } else {
        await _exit();
      }
    } finally {
      _closing = false;
    }
  }

  Future<WindowsCloseBehavior?> _askCloseBehavior() async {
    if (!mounted) return WindowsCloseBehavior.exit;
    return askWindowsCloseBehavior(context);
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuShowKey:
        unawaited(_showWindow());
      case _menuExitKey:
        unawaited(_exit());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Asks whether closing the window should exit or keep running in the tray.
///
/// Returns null when the dialog is dismissed, meaning the window stays open.
Future<WindowsCloseBehavior?> askWindowsCloseBehavior(
  BuildContext context,
) async {
  final colors = context.moeColors;
  final keepRunning = await showMeoTalkDialog(
    context: context,
    title: '关闭 AIcove',
    centered: true,
    cancelText: '完全退出',
    confirmText: '后台运行',
    content: Text(
      '后台运行时窗口会收进右下角托盘，角色的主动消息和来电照常进行；'
      '完全退出后这些都会停止。\n\n'
      '这次选择会被记住，之后可以在「设置 · 通用设置」里修改。',
      style: TextStyle(fontSize: 15, color: colors.textSecondary, height: 1.5),
    ),
  );
  if (keepRunning == null) return null;
  return keepRunning ? WindowsCloseBehavior.tray : WindowsCloseBehavior.exit;
}
