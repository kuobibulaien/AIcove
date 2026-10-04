import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/sync/cloud_setting_policy.dart';

/// Synced map of device ID -> display name. Each device only writes its own
/// field, so field-level setting merge never conflicts across devices.
const deviceNamesKey = 'aicove.devices.v1';
const lanNameKey = 'aicove.lan.name';

/// Defaults written before system names were read; treated as "not named".
const _legacyDefaults = {'我的手机或平板', '我的电脑'};

String? _systemName;

/// System device name: Android "About phone" name or manufacturer + model,
/// the Mac computer name, otherwise the host name.
Future<String> systemDeviceName() async {
  if (_systemName != null) return _systemName!;
  String? name;
  try {
    name = await const MethodChannel(
      'aicove/device_name',
    ).invokeMethod<String>('read');
  } catch (_) {
    /* Platforms without the channel use the fallback below. */
  }
  if (name == null || name.trim().isEmpty) {
    name = Platform.isIOS
        ? 'iPhone'
        : Platform.isAndroid
        ? 'Android 设备'
        : Platform.localHostname;
  }
  return _systemName = stripOwnerName(name.trim());
}

/// "张三的MacBook Pro" / "Ann's MacBook Pro" -> "MacBook Pro": the model is
/// what tells devices apart, and the owner's name need not travel.
String stripOwnerName(String name) {
  final match = RegExp(r"^.+?(?:的|'s |’s )(.+)$").firstMatch(name);
  final rest = match?.group(1)?.trim();
  return rest == null || rest.isEmpty ? name : rest;
}

/// The name shown to other devices: a user-chosen LAN name, else the system one.
Future<String> ownDeviceName(SharedPreferences preferences) async {
  final saved = preferences.getString(lanNameKey)?.trim();
  if (saved != null && saved.isNotEmpty && !_legacyDefaults.contains(saved)) {
    return saved;
  }
  return systemDeviceName();
}

Map<String, String> readDeviceNames(SharedPreferences preferences) {
  try {
    final decoded = jsonDecode(preferences.getString(deviceNamesKey) ?? '{}');
    if (decoded is Map) {
      return {
        for (final entry in decoded.entries)
          if (entry.value is String && (entry.value as String).isNotEmpty)
            entry.key as String: entry.value as String,
      };
    }
  } on FormatException {
    /* A damaged entry is replaced on the next publish. */
  }
  return {};
}

/// Records this device's current name in the synced directory.
Future<void> publishDeviceName(
  SharedPreferences preferences,
  String deviceId,
) async {
  final name = await ownDeviceName(preferences);
  final names = readDeviceNames(preferences);
  if (names[deviceId] == name) return;
  await saveCloudPreference(
    preferences,
    deviceNamesKey,
    canonicalSettingJson({...names, deviceId: name}),
  );
}

/// Label for a device: synced name, then a paired LAN name, then a short ID.
String deviceLabel(
  String id, {
  required String? ownId,
  required Map<String, String> names,
  String? ownName,
  Map<String, String> peerNames = const {},
}) {
  final live = ownName == null || ownName.isEmpty ? null : ownName;
  final name = id == ownId ? live ?? names[id] : names[id] ?? peerNames[id];
  if (id == ownId) return name == null ? '本机' : '本机 · $name';
  return name ?? '设备 ${id.substring(0, id.length.clamp(0, 8))}';
}
