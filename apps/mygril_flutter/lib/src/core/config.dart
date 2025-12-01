import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// 后端 API 基地址配置
/// 
/// 环境说明：
/// - 本地开发：http://localhost:8001 (Windows本地后端)
/// - 云端生产：http://152.136.174.211:8000 (云服务器)
/// 
/// 使用方法：
/// 1. 默认使用下面的 _defaultApiUrl
/// 2. 编译时可通过 --dart-define=API_BASE_URL=... 覆盖
/// 3. 运行时可通过 USE_LOCAL_API=true 切换到本地开发模式

/// 默认API地址（生产环境）
const String _defaultApiUrl = 'http://152.136.174.211:8000';

/// 本地开发API地址（电脑本机访问）
const String _localApiUrl = 'http://localhost:8001';

/// 局域网开发API地址（手机通过WiFi访问电脑）
const String _lanApiUrl = 'http://192.168.1.6:8001';

/// 是否使用本地API（开发模式）
/// 设置为 true 可以快速切换到本地开发环境
const bool _useLocalApi = false;  // ← 电脑本机开发用 true

/// 是否使用局域网API（手机测试模式）
/// 设置为 true 可以让手机通过WiFi连接电脑后端
const bool _useLanApi = true;  // ← 手机连电脑测试用 true

/// 编译时注入的API地址（优先级最高）
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL', 
  defaultValue: _useLanApi 
    ? _lanApiUrl      // 手机测试：连电脑WiFi
    : _useLocalApi 
      ? _localApiUrl  // 电脑开发：localhost
      : _defaultApiUrl // 云端生产：公网IP
);

/// 解析实际使用的API地址
String resolvedApiBase() {
  // Web：优先使用编译期注入的 API_BASE_URL；未注入或无效时回退到当前页面 origin（KISS）
  if (kIsWeb) {
    final base = apiBaseUrl;
    if (base.startsWith('http://') || base.startsWith('https://')) {
      return base;
    }
    return Uri.base.origin; // e.g. http://localhost:8001
  }
  
  // Android 模拟器访问宿主机时用 10.0.2.2
  if (Platform.isAndroid && apiBaseUrl.contains('localhost')) {
    return apiBaseUrl.replaceAll('localhost', '10.0.2.2');
  }
  
  return apiBaseUrl;
}

