import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_plugins/url_strategy.dart';
import 'src/app.dart';
import 'src/core/app_logger.dart';

import 'src/features/chat/data/background_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化后台服务 (WorkManager) - 仅在非 Web 平台执行
  // 原因：WorkManager 不支持 Web，会导致初始化失败
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
