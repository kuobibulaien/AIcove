import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_local_write.dart';

const cloudUiModelsKey = 'aicove.ui_models.v1';
const cloudPreferenceTimesKey = 'aicove.sync.setting_times.v1';

/// 隐私空间密码哈希，随设置同步（ADR0070）。
const privacySpacePasswordKey = 'aicove.privacy_space.v1';

/// Fields owned by the General page remain on the current device. Model,
/// provider and plugin configuration keep their own scope.
const localGeneralSettings = <String>{
  'message_chunking_enabled',
  'message_format_config',
  'stream_segment_delay_seconds',
  'chat_display_style',
  'auto_scroll_on_send',
  'text_scale_factor',
  'ui_scale_factor',
  'image_preview_scale',
  'windows_window_controls_side',
  'chat_background_color',
  'global_background_color',
  'global_wallpaper',
  'global_wallpaper_custom_image',
  'global_wallpaper_mask',
  'is_dark_mode',
  'use_system_theme',
  'hide_user_avatar',
  'expand_audio_text',
  'skip_vision_compat_dialog',
  'interface_skin',
  'accent_color',
  'glass_effect_enabled',
  'glass_blur_sigma',
  'glass_tint_fill',
  'use_liquid_glass',
  'user_name',
  'user_avatar',
};

String canonicalSettingJson(Object? value) {
  Object? sort(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sort(value[key])};
    }
    if (value is List) return value.map(sort).toList();
    return value;
  }

  return jsonEncode(sort(value));
}

String settingFingerprint(Object? value) =>
    sha256.convert(utf8.encode(canonicalSettingJson(value))).toString();

Map<String, dynamic> cloudPreferenceFields(String key, Object? value) {
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (key != cloudUiModelsKey ||
                !localGeneralSettings.contains(entry.key))
              entry.key as String: entry.value,
        };
      }
    } on FormatException {
      /* A plain string is one setting. */
    }
  }
  return {'value': value};
}

Object? projectCloudPreference(String key, Object? value) {
  if (value is! String) return value;
  try {
    if (jsonDecode(value) is Map) {
      return canonicalSettingJson(cloudPreferenceFields(key, value));
    }
  } on FormatException {
    /* Preserve plain string preferences. */
  }
  return value;
}

Map<String, dynamic> preferenceTimeJournal(SharedPreferences preferences) =>
    Map<String, dynamic>.from(
      jsonDecode(preferences.getString(cloudPreferenceTimesKey) ?? '{}') as Map,
    );

Future<bool> _writePreference(
  SharedPreferences preferences,
  String key,
  Object? value,
) {
  if (value == null) return preferences.remove(key);
  if (value is String) return preferences.setString(key, value);
  if (value is bool) return preferences.setBool(key, value);
  if (value is int) return preferences.setInt(key, value);
  if (value is double) return preferences.setDouble(key, value);
  if (value is List<String>) return preferences.setStringList(key, value);
  throw ArgumentError('Unsupported preference type');
}

/// Record at the actual local write, including offline edits. Fingerprints
/// prevent a partially persisted journal from assigning a time to wrong data.
Future<bool> saveCloudPreference(
  SharedPreferences preferences,
  String key,
  Object? value, {
  int? atMs,
}) => cloudLocalWrite(() async {
  final oldFields = cloudPreferenceFields(key, preferences.get(key));
  final fields = cloudPreferenceFields(key, value);
  final journal = preferenceTimeJournal(preferences);
  final previousJournal = jsonEncode(journal);
  final times = Map<String, dynamic>.from(journal[key] as Map? ?? {});
  for (final field in {...oldFields.keys, ...fields.keys}) {
    if (oldFields.containsKey(field) == fields.containsKey(field) &&
        settingFingerprint(oldFields[field]) ==
            settingFingerprint(fields[field])) {
      continue;
    }
    final previous = times[field] as Map?;
    final previousAt = (previous?['at_ms'] as num?)?.toInt() ?? 0;
    final now = atMs ?? DateTime.now().millisecondsSinceEpoch;
    times[field] = {
      'at_ms': now > previousAt ? now : previousAt + 1,
      'device_id': '',
      'fingerprint': settingFingerprint(fields[field]),
      'present': fields.containsKey(field),
    };
  }
  journal[key] = times;
  if (!await preferences.setString(
    cloudPreferenceTimesKey,
    jsonEncode(journal),
  )) {
    return false;
  }
  if (await _writePreference(preferences, key, value)) return true;
  if (!await preferences.setString(cloudPreferenceTimesKey, previousJournal)) {
    throw StateError('Setting clock rollback failed');
  }
  return false;
});

Map<String, dynamic> cloudPreferenceTimes(
  SharedPreferences preferences,
  String key,
  Object? value,
  String device,
) {
  final fields = cloudPreferenceFields(key, value);
  final times = preferenceTimeJournal(preferences)[key] as Map? ?? {};
  return {
    for (final entry in times.entries)
      if ((entry.value as Map)['present'] == fields.containsKey(entry.key) &&
          (entry.value as Map)['fingerprint'] ==
              settingFingerprint(fields[entry.key]))
        entry.key as String: {
          'at_ms': (entry.value as Map)['at_ms'],
          'device_id': (entry.value as Map)['device_id'] == ''
              ? device
              : (entry.value as Map)['device_id'],
        },
  };
}

Future<void> rememberCloudPreferenceTimes(
  SharedPreferences preferences,
  String key,
  Object? value,
  Map times,
) async {
  final fields = cloudPreferenceFields(key, value);
  final journal = preferenceTimeJournal(preferences);
  journal[key] = {
    for (final entry in times.entries)
      if (key != cloudUiModelsKey || !localGeneralSettings.contains(entry.key))
        entry.key as String: {
          ...Map<String, dynamic>.from(entry.value as Map),
          'fingerprint': settingFingerprint(fields[entry.key]),
          'present': fields.containsKey(entry.key),
        },
  };
  if (!await preferences.setString(
    cloudPreferenceTimesKey,
    jsonEncode(journal),
  )) {
    throw StateError('Remote setting clocks could not be saved');
  }
}

Object? keepLocalGeneralSettings(String key, Object? incoming, Object? local) {
  if (key != cloudUiModelsKey || incoming is! String) return incoming;
  final fields = cloudPreferenceFields(key, incoming);
  final current = local is String ? jsonDecode(local) as Map : const {};
  return jsonEncode({
    ...fields,
    for (final entry in current.entries)
      if (localGeneralSettings.contains(entry.key))
        entry.key as String: entry.value,
  });
}
