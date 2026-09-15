import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../features/settings/app_settings.dart';

const MethodChannel _keepAliveChannel =
    MethodChannel('com.example.aicove_flutter/keep_alive');

class AndroidKeepAliveStatus {
  final bool guardEnabled;
  final bool generationActive;
  final bool serviceRunning;
  final bool batteryOptimizationIgnored;
  final bool canScheduleExactAlarms;
  final bool notificationPermissionGranted;
  final bool notificationsEnabled;
  final bool guardNotificationChannelEnabled;
  final bool notificationVisibleInDrawer;
  final String lastStartError;
  final String manufacturer;
  final String brand;
  final String model;

  const AndroidKeepAliveStatus({
    required this.guardEnabled,
    required this.generationActive,
    required this.serviceRunning,
    required this.batteryOptimizationIgnored,
    required this.canScheduleExactAlarms,
    required this.notificationPermissionGranted,
    required this.notificationsEnabled,
    required this.guardNotificationChannelEnabled,
    required this.notificationVisibleInDrawer,
    required this.lastStartError,
    required this.manufacturer,
    required this.brand,
    required this.model,
  });

  factory AndroidKeepAliveStatus.fromMap(Map<dynamic, dynamic> map) {
    String readString(String key) => map[key]?.toString().trim() ?? '';

    return AndroidKeepAliveStatus(
      guardEnabled: map['guardEnabled'] == true,
      generationActive: map['generationActive'] == true,
      serviceRunning: map['serviceRunning'] == true,
      batteryOptimizationIgnored: map['batteryOptimizationIgnored'] == true,
      canScheduleExactAlarms: map['canScheduleExactAlarms'] == true,
      notificationPermissionGranted:
          map['notificationPermissionGranted'] == true,
      notificationsEnabled: map['notificationsEnabled'] == true,
      guardNotificationChannelEnabled:
          map['guardNotificationChannelEnabled'] != false,
      notificationVisibleInDrawer: map['notificationVisibleInDrawer'] == true,
      lastStartError: readString('lastStartError'),
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

class AndroidGenerationKeepAliveLease {
  AndroidGenerationKeepAliveLease._(this._id);

  final int _id;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await AndroidKeepAliveManager._releaseGenerationLease(_id);
  }
}

class AndroidKeepAliveManager {
  static int _nextGenerationLeaseId = 0;
  static final Set<int> _activeGenerationLeaseIds = <int>{};

  static bool get isSupported => Platform.isAndroid;

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
    final status = map == null ? null : AndroidKeepAliveStatus.fromMap(map);
    return _waitForStableGuardState(enabled, fallback: status);
  }

  static Future<void> syncWithAutoReplySettings(
    AutoReplySettings settings,
  ) async {
    if (!isSupported) return;
    // 主动回复开启后直接拉起前台保活；guardModeEnabled 仅保留旧配置兼容。
    final desiredEnabled = settings.enabled;
    final status = await getStatus();
    if (status == null) return;

    final needsUpdate = status.guardEnabled != desiredEnabled ||
        (desiredEnabled && !status.serviceRunning);
    if (!needsUpdate) return;

    await setGuardEnabled(desiredEnabled);
  }

  /// 在聊天生成期间临时提升 Android 进程优先级，并保持 CPU 可运行。
  ///
  /// 每个调用方必须在生成结束或中断时释放返回的租约。多个并行生成会共享
  /// 同一个原生前台服务，只有最后一个租约释放后才结束“生成中”状态。
  static Future<AndroidGenerationKeepAliveLease?>
      acquireGenerationLease() async {
    if (!isSupported) return null;

    final leaseId = ++_nextGenerationLeaseId;
    _activeGenerationLeaseIds.add(leaseId);
    try {
      await _keepAliveChannel.invokeMethod<void>(
        'setGenerationActive',
        {'active': true},
      );
      return AndroidGenerationKeepAliveLease._(leaseId);
    } catch (_) {
      _activeGenerationLeaseIds.remove(leaseId);
      rethrow;
    }
  }

  static Future<void> _releaseGenerationLease(int leaseId) async {
    if (!_activeGenerationLeaseIds.remove(leaseId)) return;
    if (_activeGenerationLeaseIds.isNotEmpty || !isSupported) return;

    await _keepAliveChannel.invokeMethod<void>(
      'setGenerationActive',
      {'active': false},
    );
  }

  static Future<bool> openNotificationSettings() =>
      _invokeBool('openNotificationSettings');

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

  static Future<AndroidKeepAliveStatus?> _waitForStableGuardState(
    bool enabled, {
    AndroidKeepAliveStatus? fallback,
  }) async {
    var latest = fallback;
    const maxAttempts = 8;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      latest ??= await getStatus();
      if (latest == null) return null;

      if (!enabled) {
        final fullyStopped = !latest.guardEnabled && !latest.serviceRunning;
        if (fullyStopped) return latest;
      } else {
        final started = latest.guardEnabled && latest.serviceRunning;
        final failed = latest.lastStartError.trim().isNotEmpty ||
            (!latest.guardEnabled && attempt > 0);
        if (started || failed) return latest;
      }

      await Future<void>.delayed(const Duration(milliseconds: 180));
      latest = await getStatus();
    }

    return latest;
  }

  static Future<bool> _invokeBool(String method) async {
    if (!isSupported) return false;
    final result = await _keepAliveChannel.invokeMethod<bool>(method);
    return result == true;
  }
}
