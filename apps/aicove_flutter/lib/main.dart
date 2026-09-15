import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/core/app_logger.dart';
import 'src/ui/theme/tokens.dart';
import 'src/core/frontend_error_capture.dart';
import 'src/features/observability/frontend_diagnostics_service.dart';
import 'src/features/observability/diagnostic_runtime_identity.dart';
import 'src/features/observability/diagnostic_access_service.dart';
import 'src/core/network/windows_proxy_http_overrides.dart';
import 'src/features/auto_reply/data/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FrontendErrorCapture(FrontendDiagnosticsService.instance).install();
  FrontendDiagnosticsService.instance
      .setRuntimeIdentity(await readDiagnosticRuntimeIdentity());

  // 安全预热液态玻璃着色器（捕获异常并自动记录，不阻断主启动流程）
  await MoeLiquidGlassService.initialize();

  // On Android this auto-detects system proxy & local proxy apps (Clash/V2Ray).
  await installProxyHttpOverrides();

  // Window setup for desktop platforms.
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      size: const Size(1200, 800),
      minimumSize: const Size(400, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: Platform.isMacOS,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      if (Platform.isMacOS) {
        await const MethodChannel('aicove/window_chrome')
            .invokeMethod<void>('alignTrafficLights');
      }
    });

    AppLogger.info('App', 'Desktop window initialization completed');
  }

  // WorkManager is initialized only on mobile.
  if (Platform.isAndroid || Platform.isIOS) {
    BackgroundService.initialize().then((_) {
      AppLogger.info('App', 'Background service initialization completed');
    }).catchError((e) {
      AppLogger.error('App', 'Background service initialization failed: $e');
    });
  } else {
    AppLogger.info('App', 'Background service skipped on desktop');
  }

  AppLogger.info('App', 'App is starting');

  AppLogger.info('App', 'App startup completed');

  runApp(const ProviderScope(child: MyApp()));
  DiagnosticAccessService.instance.startAutomatically();
}
