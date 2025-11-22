import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// 后端 API 基地址
/// - 可通过 --dart-define=API_BASE_URL=... 注入
const String apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8000');

/// Android 模拟器访问宿主机时用 10.0.2.2
String resolvedApiBase() {
  // Web：优先使用编译期注入的 API_BASE_URL；未注入或无效时回退到当前页面 origin（KISS）
  if (kIsWeb) {
    final base = apiBaseUrl;
    if (base.startsWith('http://') || base.startsWith('https://')) {
      return base;
    }
    return Uri.base.origin; // e.g. http://localhost:8001
  }
  if (Platform.isAndroid && apiBaseUrl.contains('localhost')) {
    return apiBaseUrl.replaceAll('localhost', '10.0.2.2');
  }
  return apiBaseUrl;
}

