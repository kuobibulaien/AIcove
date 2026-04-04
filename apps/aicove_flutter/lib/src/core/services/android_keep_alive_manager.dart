import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../../features/settings/app_settings.dart';

const MethodChannel _keepAliveChannel =
    MethodChannel('com.example.aicove_flutter/keep_alive');

class AndroidKeepAliveStatus {
  final bool guardEnabled;
  final bool serviceRunning;
  final bool batteryOptimizationIgnored;
  final bool canScheduleExactAlarms;
  final bool notificationsEnabled;
  final String manufacturer;
  final String brand;
  final String model;

  const AndroidKeepAliveStatus({
    required this.guardEnabled,
    required this.serviceRunning,
    required this.batteryOptimizationIgnored,
    required this.canScheduleExactAlarms,
    required this.notificationsEnabled,
    required this.manufacturer,
    required this.brand,
    required this.model,
  });

  factory AndroidKeepAliveStatus.fromMap(Map<dynamic, dynamic> map) {
    String readString(String key) => map[key]?.toString().trim() ?? '';

    return AndroidKeepAliveStatus(
      guardEnabled: map['guardEnabled'] == true,
      serviceRunning: map['serviceRunning'] == true,
      batteryOptimizationIgnored: map['batteryOptimizationIgnored'] == true,
      canScheduleExactAlarms: map['canScheduleExactAlarms'] == true,
      notificationsEnabled: map['notificationsEnabled'] == true,
      manufacturer: readString('manufacturer'),
      brand: readString('brand'),
      model: readString('model'),
    );
  }

  String get deviceLabel {
    final parts = <String>[
      if (manufacturer.isNotEmpty) manufacturer,
      if (model.isNotEmpty) model,
    ];
    return parts.join(' ').trim();
  }

  bool get isXiaomi {
    final normalized = manufacturer.toLowerCase();
    return normalized.contains('xiaomi') || normalized.contains('redmi');
  }
}

class AndroidKeepAliveManager {
  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<AndroidKeepAliveStatus?> getStatus() async {
    if (!isSupported) return null;
    final map = await _keepAliveChannel.invokeMapMethod<String, dynamic>(
      'getStatus',
    );
    if (map == null) return null;
    return AndroidKeepAliveStatus.fromMap(map);
  }

  static Future<AndroidKeepAliveStatus?> setGuardEnabled(bool enabled) async {
    if (!isSupported) return null;
    final map = await _keepAliveChannel.invokeMapMethod<String, dynamic>(
      'setGuardEnabled',
      {'enabled': enabled},
    );
    if (map == null) return null;
    return AndroidKeepAliveStatus.fromMap(map);
  }

  static Future<void> syncWithAutoReplySettings(
    AutoReplySettings settings,
  ) async {
    if (!isSupported) return;
    final desiredEnabled = settings.enabled && settings.guardModeEnabled;
    final status = await getStatus();
    if (status == null) return;

    final needsUpdate = status.guardEnabled != desiredEnabled ||
        (desiredEnabled && !status.serviceRunning);
    if (!needsUpdate) return;

    await setGuardEnabled(desiredEnabled);
  }

  static Future<bool> requestIgnoreBatteryOptimizations() =>
      _invokeBool('requestIgnoreBatteryOptimizations');

  static Future<bool> openBatteryOptimizationSettings() =>
      _invokeBool('openBatteryOptimizationSettings');

  static Future<bool> openAutoStartSettings() =>
      _invokeBool('openAutoStartSettings');

  static Future<bool> openBackgroundProtectionSettings() =>
      _invokeBool('openBackgroundProtectionSettings');

  static Future<bool> openExactAlarmSettings() =>
      _invokeBool('openExactAlarmSettings');

  static Future<bool> _invokeBool(String method) async {
    if (!isSupported) return false;
    final result = await _keepAliveChannel.invokeMethod<bool>(method);
    return result == true;
  }
}
