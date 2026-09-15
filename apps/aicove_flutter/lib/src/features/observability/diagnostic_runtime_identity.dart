import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 构建快照来自 native BuildConfig；其他平台/旧壳必须诚实标为 unknown。
Future<Map<String, Object?>> readDiagnosticRuntimeIdentity() async {
  final result = <String, Object?>{
    'buildId': 'unknown',
    'flutterMode':
        kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    'identityScope': 'unavailable',
  };
  try {
    final native = await const MethodChannel(
            'com.example.aicove_flutter/diagnostic_identity')
        .invokeMapMethod<String, Object?>('read')
        .timeout(const Duration(milliseconds: 500));
    for (final key in const [
      'buildId',
      'buildType',
      'versionName',
      'versionCode',
      'deviceModel',
      'androidApi',
      'identityScope'
    ]) {
      final value = native?[key];
      if (value is num || (value is String && value.length <= 128)) {
        result[key] = value;
      }
    }
  } catch (error) {
    result['identityErrorType'] = error.runtimeType.toString();
  }
  final views = PlatformDispatcher.instance.views;
  if (views.isNotEmpty) {
    final view = views.first;
    result.addAll({
      'refreshRate': view.display.refreshRate,
      'physicalWidth': view.physicalSize.width,
      'physicalHeight': view.physicalSize.height,
      'devicePixelRatio': view.devicePixelRatio
    });
  }
  return result;
}
