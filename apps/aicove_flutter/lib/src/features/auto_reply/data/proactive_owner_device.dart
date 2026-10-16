import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/media/media_store.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_setting_policy.dart';

/// Synced map of conversation ID -> the device that answers proactively for
/// it: the one the user last spoke from. Triggers sync to every device, so
/// without an owner each device would analyse and send on its own.
///
/// Each conversation is one field holding `{device_id, at_ms}`, so the
/// field-level setting merge keeps the latest claim per conversation. The
/// claim time is part of the value: a device speaking again must win over an
/// earlier claim from another device that has not reached it yet, and an
/// unchanged value would keep its old merge time. The trigger plugin prefix
/// is already on the sync whitelist of older clients.
const proactiveOwnerDevicesKey = 'aicove.plugins.trigger.owner_devices.v1';

class ProactiveOwnership {
  const ProactiveOwnership._(this.deviceId, this._owners);

  final String deviceId;
  final Map<String, String> _owners;

  static Future<ProactiveOwnership> load() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    return ProactiveOwnership._(
      await MediaStore.localDeviceId,
      _read(preferences),
    );
  }

  /// A conversation nobody has claimed yet (before the first user message
  /// after upgrading) stays with every device, as before.
  bool owns(String conversationId) {
    final owner = _owners[conversationId.trim()];
    return owner == null || owner == deviceId;
  }

  /// Records this device as the owner of [conversationId], on every user
  /// message, even when it already owns it.
  /// Reading and saving run under the sync write lock, so another
  /// conversation's owner applied by sync in between is not overwritten.
  static Future<void> claim(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty) return;
    final deviceId = await MediaStore.localDeviceId;
    await cloudLocalWrite(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.reload();
      await saveCloudPreference(
        preferences,
        proactiveOwnerDevicesKey,
        canonicalSettingJson({
          ..._decode(preferences),
          id: {
            'device_id': deviceId,
            'at_ms': DateTime.now().millisecondsSinceEpoch,
          },
        }),
      );
    });
  }

  static Map<String, String> _read(SharedPreferences preferences) => {
        for (final entry in _decode(preferences).entries)
          if (entry.value case {'device_id': final String device})
            entry.key: device,
      };

  static Map<String, dynamic> _decode(SharedPreferences preferences) {
    try {
      final decoded = jsonDecode(
        preferences.getString(proactiveOwnerDevicesKey) ?? '{}',
      );
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      /* A damaged map is replaced by the next claim. */
    }
    return {};
  }
}
