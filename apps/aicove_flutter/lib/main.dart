import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/core/app_logger.dart';
import 'src/core/network/windows_proxy_http_overrides.dart';
import 'src/features/auto_reply/data/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Install platform-aware proxy overrides for all non-web platforms.
  // On Android this auto-detects system proxy & local proxy apps (Clash/V2Ray).
  if (!kIsWeb) {
    await installProxyHttpOverrides();
  }

  // Window setup for desktop platforms.
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

    AppLogger.info('App', 'Desktop window initialization completed');
  }

  // WorkManager is initialized only on mobile.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    BackgroundService.initialize().then((_) {
      AppLogger.info('App', 'Background service initialization completed');
    }).catchError((e) {
      AppLogger.error('App', 'Background service initialization failed: $e');
    });
  } else if (kIsWeb) {
    AppLogger.info('App', 'Background service skipped on web');
  } else {
    AppLogger.info('App', 'Background service skipped on desktop');
  }

  AppLogger.info('App', 'App is starting');

  // Use hash URL strategy on web.
  if (kIsWeb) {
    setUrlStrategy(const HashUrlStrategy());
    AppLogger.debug('App', 'Using Hash URL strategy for web');
  }

  AppLogger.info('App', 'App startup completed');

  runApp(const ProviderScope(child: MyApp()));
}
