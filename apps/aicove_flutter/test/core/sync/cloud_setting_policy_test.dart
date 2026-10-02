import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all General fields are local while model and plugin fields remain portable',
    () {
      final value = jsonEncode({
        for (final key in localGeneralSettings) key: 'local',
        'default_model': 'shared',
        'providers': ['provider'],
      });
      expect(
        jsonDecode(projectCloudPreference(cloudUiModelsKey, value) as String),
        {
          'default_model': 'shared',
          'providers': ['provider'],
        },
      );
      final received = keepLocalGeneralSettings(
        cloudUiModelsKey,
        jsonEncode({'default_model': 'cloud', 'is_dark_mode': false}),
        jsonEncode({'default_model': 'old', 'is_dark_mode': true}),
      );
      expect(jsonDecode(received as String), {
        'default_model': 'cloud',
        'is_dark_mode': true,
      });
    },
  );

  test(
    'local edits are timestamped immediately and a backward clock stays monotonic',
    () async {
      const key = 'aicove.plugins.test.config';
      SharedPreferences.setMockInitialValues({
        key: '{"voice":"base","model":"base"}',
      });
      final prefs = await SharedPreferences.getInstance();
      await saveCloudPreference(
        prefs,
        key,
        '{"voice":"changed","model":"base"}',
        atMs: 100,
      );
      var times = cloudPreferenceTimes(prefs, key, prefs.get(key), 'phone');
      expect(times.keys, ['voice']);
      expect(times['voice'], {'at_ms': 100, 'device_id': 'phone'});
      await saveCloudPreference(
        prefs,
        key,
        '{"voice":"newer","model":"base"}',
        atMs: 90,
      );
      times = cloudPreferenceTimes(prefs, key, prefs.get(key), 'phone');
      expect(times['voice']['at_ms'], 101);
      await saveCloudPreference(
        prefs,
        key,
        '{"voice":"newer","model":"base"}',
        atMs: 500,
      );
      expect(
        cloudPreferenceTimes(
          prefs,
          key,
          prefs.get(key),
          'phone',
        )['voice']['at_ms'],
        101,
      );
    },
  );

  test('changing only General settings does not record a cloud edit', () async {
    SharedPreferences.setMockInitialValues({
      cloudUiModelsKey: '{"default_model":"same","is_dark_mode":false}',
    });
    final prefs = await SharedPreferences.getInstance();
    await saveCloudPreference(
      prefs,
      cloudUiModelsKey,
      '{"default_model":"same","is_dark_mode":true}',
      atMs: 100,
    );
    expect(
      cloudPreferenceTimes(
        prefs,
        cloudUiModelsKey,
        prefs.get(cloudUiModelsKey),
        'phone',
      ),
      isEmpty,
    );
  });

  test(
    'remote clocks survive a new local write and clearing retains its time',
    () async {
      const key = 'aicove.plugins.test.config';
      SharedPreferences.setMockInitialValues({key: '{"voice":"cloud"}'});
      final prefs = await SharedPreferences.getInstance();
      await rememberCloudPreferenceTimes(prefs, key, prefs.get(key), {
        'voice': {'at_ms': 300, 'device_id': 'phone'},
      });
      expect(
        cloudPreferenceTimes(
          prefs,
          key,
          prefs.get(key),
          'mac',
        )['voice']['device_id'],
        'phone',
      );
      await saveCloudPreference(prefs, key, '{}', atMs: 200);
      final times = cloudPreferenceTimes(prefs, key, prefs.get(key), 'mac');
      expect(times['voice'], {'at_ms': 301, 'device_id': 'mac'});
    },
  );

  test(
    'a journal for another value cannot assign its clock to current data',
    () async {
      const key = 'aicove.plugins.test.config';
      SharedPreferences.setMockInitialValues({key: '{"voice":"base"}'});
      final prefs = await SharedPreferences.getInstance();
      await saveCloudPreference(prefs, key, '{"voice":"edited"}', atMs: 100);
      await prefs.setString(key, '{"voice":"different"}');
      expect(
        cloudPreferenceTimes(prefs, key, prefs.get(key), 'phone'),
        isEmpty,
      );
    },
  );
}
