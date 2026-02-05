import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:window_manager/window_manager.dart';
import 'src/app.dart';
import 'src/core/app_logger.dart';

import 'src/features/chat/data/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows/macOS/Linux 桌面端窗口配置
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1200, 800),
      minimumSize: Size(400, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    AppLogger.info('App', 'Windows 无边框窗口初始化完成');
  }

  // 初始化后台服务 (WorkManager) - 仅在非 Web 平台执行
  if (!kIsWeb) {
    BackgroundService.initialize().then((_) {
      AppLogger.info('App', '后台服务初始化完成');
    }).catchError((e) {
      AppLogger.error('App', '后台服务初始化失败: $e');
    });
  } else {
    AppLogger.info('App', 'Web 平台跳过后台服务初始化');
  }

  // 初始化日志系统
  AppLogger.info('App', '应用启动中...');

  // Web 使用 Hash 路由，避免服务端回退处理
  if (kIsWeb) {
    setUrlStrategy(const HashUrlStrategy());
    AppLogger.debug('App', '使用 Hash URL 策略 (Web 平台)');
  }

  AppLogger.info('App', '应用启动完成');

  runApp(const ProviderScope(child: MyApp()));
}
