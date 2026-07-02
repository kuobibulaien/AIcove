import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;

/// 平台工具类，用于判断当前运行平台
class PlatformUtils {
  /// 是否为 Web 平台
  static bool get isWeb => kIsWeb;

  /// 是否为移动平台（Android 或 iOS）
  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 是否为桌面平台（Windows、macOS 或 Linux）
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 是否支持后台任务（workmanager）
  static bool get supportsBackgroundTasks => isMobile;

  /// 是否支持本地通知
  static bool get supportsLocalNotifications => !kIsWeb;

  /// 是否支持文件系统完整访问
  static bool get supportsFileSystem => !kIsWeb;

  /// 是否支持保存到相册
  static bool get supportsGallerySaver => isMobile;

  /// 是否支持窗口管理
  static bool get supportsWindowManager => isDesktop;
}
