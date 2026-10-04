import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/media/media_resolver.dart';
import 'package:aicove_flutter/src/features/account/data/account_repository.dart';
import 'package:aicove_flutter/src/features/account/domain/account_port.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_scheduler.dart';
import 'package:aicove_flutter/src/features/sync/data/device_names.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';

class MemoryPreferences implements SharedPreferences {
  final values = <String, Object>{};
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Object? get(String key) => values[key];
  @override
  String? getString(String key) => values[key] as String?;
  @override
  int? getInt(String key) => values[key] as int?;
  @override
  Future<void> reload() async {}
  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  Future<bool> put(String key, Object value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) => put(key, value);
  @override
  Future<bool> setBool(String key, bool value) => put(key, value);
  @override
  Future<bool> setInt(String key, int value) => put(key, value);
  @override
  Future<bool> setDouble(String key, double value) => put(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) => put(key, value);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DropResponse implements CloudRemote {
  DropResponse(this.api);
  final CloudRemote api;
  bool dropNextMessage = false, dropNextUpload = false;
  bool dropNextSetting = false;
  int pushRequests = 0, receivedBusinessDocuments = 0;
  int activeDownloads = 0, peakDownloads = 0;
  Completer<void>? downloadGate;
  Future<void> Function()? afterMessagePush;
  Future<void> Function()? afterSettingPush;
  bool failDownloads = false;
  final uploadBatchSizes = <int>[];
  final uploadedDigests = <String>[];
  final readStages = <String>[];
  final getPaths = <String>[];
  final publishedKinds = <String>{};
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == 'push') {
      pushRequests++;
      publishedKinds.addAll(
        (body['mutations'] as List).map((row) => row['kind'] as String),
      );
    }
    final result = await api.post(path, body);
    if (path == 'push' &&
        (body['mutations'] as List).any((m) => m['kind'] == 'conversations')) {
      final callback = afterSettingPush;
      afterSettingPush = null;
      await callback?.call();
      if (dropNextSetting) {
        dropNextSetting = false;
        throw const SocketException(
          'fixture setting response lost after server commit',
        );
      }
    }
    if (path == 'push' &&
        (body['mutations'] as List).any((m) => m['kind'] == 'messages')) {
      final callback = afterMessagePush;
      afterMessagePush = null;
      await callback?.call();
    }
    if (dropNextMessage &&
        path == 'push' &&
        (body['mutations'] as List).any(
          (mutation) => mutation['kind'] == 'messages',
        )) {
      dropNextMessage = false;
      throw const SocketException('fixture response lost after server commit');
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    getPaths.add(path);
    final response = await api.get(path, query);
    if (path == 'read') {
      readStages.add(query?['stage'] as String? ?? 'delta');
      receivedBusinessDocuments += (response['documents'] as List)
          .where((d) => d['kind'] == 'messages')
          .length;
    }
    return response;
  }

  @override
  Future<void> upload(String digest, File file) => api.upload(digest, file);
  @override
  Future<void> uploadBatch(Map<String, File> files) async {
    uploadBatchSizes.add(files.length);
    uploadedDigests.addAll(files.keys);
    await api.uploadBatch(files);
    if (dropNextUpload) {
      dropNextUpload = false;
      throw const SocketException('fixture upload acknowledgement lost');
    }
  }

  @override
  Future<void> download(String digest, File file) async {
    activeDownloads++;
    if (activeDownloads > peakDownloads) peakDownloads = activeDownloads;
    try {
      await downloadGate?.future;
      if (failDownloads) {
        throw const SocketException('fixture media unavailable');
      }
      await api.download(digest, file);
    } finally {
      activeDownloads--;
    }
  }

  @override
  void close() => api.close();
}

class Device {
  Device(this.local, this.media, this.remote, this.sync);
  final CloudLocalStore local;
  final MediaStore media;
  final DropResponse remote;
  final CloudSyncEngine sync;
}

void main() {
  final now = DateTime.utc(2026, 9, 13);
  Process? server;
  late String address;
  late Directory temporary;
  final devices = <Device>[];
  var account = 0;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final backend = Platform.environment['AICOVE_SYNC_TEST_BACKEND'];
    final python = Platform.environment['AICOVE_SYNC_TEST_PYTHON'];
    if (backend == null || python == null) {
      throw StateError(
        'Set AICOVE_SYNC_TEST_BACKEND and AICOVE_SYNC_TEST_PYTHON to the backend checkout and its Python executable',
      );
    }
    final startedServer = await Process.start(python, [
      '$backend/tests/serve_flutter_fixture.py',
    ], workingDirectory: backend);
    server = startedServer;
    startedServer.stderr.transform(utf8.decoder).listen((text) {
      stderr.write(text);
    });
    final ready = Completer<String>();
    startedServer.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('READY ') && !ready.isCompleted) {
            ready.complete(line.substring(6));
          }
        });
    address =
        'http://127.0.0.1:${await ready.future.timeout(const Duration(seconds: 20))}';
  });
  tearDownAll(() async {
    final startedServer = server;
    if (startedServer == null) return;
    startedServer.kill();
    await startedServer.exitCode;
  });
  setUp(() async {
    account++;
    temporary = await Directory.systemTemp.createTemp('sync-device-');
  });
  tearDown(() async {
    for (final device in devices) {
      device.sync.close();
      await device.media.close();
      await device.local.db.close();
    }
    devices.clear();
    await temporary.delete(recursive: true);
  });

  Future<Device> device(String name) async {
    final auth = await const CloudAccountApi().login(
      address,
      'fixture$account',
      'integration-test-password',
    );
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = MemoryPreferences();
    final docs = Directory('${temporary.path}/$name/docs')
      ..createSync(recursive: true);
    final support = Directory('${temporary.path}/$name/support')
      ..createSync(recursive: true);
    final local = CloudLocalStore(db, preferences, docs, support);
    final media = MediaStore(Directory('${support.path}/media'), name);
    final remote = DropResponse(
      CloudApi(
        AccountConnection(
          server: address,
          user: auth.user,
          token: auth.accessToken,
        ),
      ),
    );
    final sync = CloudSyncEngine(
      local,
      remote,
      media,
      'account-$account',
      clock: () => now,
    );
    final result = Device(local, media, remote, sync);
    devices.add(result);
    return result;
  }

  Future<void> seed(Device phone, {bool images = false}) async {
    final old = now.subtract(const Duration(days: 45)).millisecondsSinceEpoch;
    await phone.local.execute(
      'INSERT INTO conversations(id,title,display_name,created_at,updated_at,enabled_plugins,recipe_id) VALUES(?,?,?,?,?,?,?)',
      [
        'role',
        'Fixture',
        'Fixture',
        old,
        old,
        '["tts","image","memory"]',
        'preset',
      ],
    );
    await phone.local.execute(
      'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
      [
        'text',
        'role',
        'assistant',
        '<tts>原文</tts><draw>标签</draw>',
        old,
        '{"tool_calls":[{"arguments":"raw"}],"parameters":{"seed":42}}',
      ],
    );
    if (!images) return;
    for (final recent in [false, true]) {
      final name = recent ? 'recent' : 'old';
      final picture = img.Image(width: 800, height: 600);
      img.fill(picture, color: img.ColorRgb8(recent ? 20 : 200, 50, 100));
      final file = File('${phone.local.documents.path}/$name.png')
        ..writeAsBytesSync(img.encodePng(picture));
      final block = {
        'id': 'block-$name',
        'messageId': name,
        'type': 'image',
        'localPath': file.path,
        'url': 'https://expired.invalid/$name',
        'generationSnapshot': {'seed': 42, 'prompt': 'fixture'},
      };
      final at = recent ? now.millisecondsSinceEpoch : old;
      await phone.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
        [
          name,
          'role',
          'assistant',
          '[图片]',
          at,
          jsonEncode({
            'blocks': [block],
          }),
        ],
      );
      await phone.local.execute(
        'INSERT INTO message_blocks(id,message_id,type,data,created_at) VALUES(?,?,?,?,?)',
        ['block-$name', name, 'image', jsonEncode(block), at],
      );
    }
  }

  Future<void> editSetting(
    Device device,
    String field,
    String? value,
    int at,
  ) async {
    await device.local.execute(
      'UPDATE conversations SET "$field"=? WHERE id=?',
      [value, 'role'],
    );
    await device.local.execute(
      'UPDATE cloud_setting_times SET at_ms=? WHERE kind=? AND entity_id=? AND field=?',
      [at, 'conversations', 'role', field],
    );
  }

  test(
    'field edit clocks merge offline settings and apply receipts on both devices',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await editSetting(phone, 'chat_background_image', 'phone-wallpaper', 200);
      await editSetting(mac, 'voice_file', 'mac-voice', 300);
      await phone.sync.synchronize();
      await mac.sync.synchronize();
      await phone.sync.synchronize();
      for (final device in [phone, mac]) {
        final row = (await device.local.rows(
          "SELECT chat_background_image,voice_file FROM conversations WHERE id='role'",
        )).single;
        expect(row['chat_background_image'], 'phone-wallpaper');
        expect(row['voice_file'], 'mac-voice');
        expect((await device.sync.previewConflicts())['conflicts'], isEmpty);
      }
      await editSetting(mac, 'chat_background_image', 'older-wallpaper', 100);
      await mac.sync.synchronize();
      expect(
        (await mac.local.rows(
          "SELECT chat_background_image FROM conversations WHERE id='role'",
        )).single['chat_background_image'],
        'phone-wallpaper',
      );
      await editSetting(mac, 'chat_background_image', null, 400);
      await mac.sync.synchronize();
      await phone.sync.synchronize();
      expect(
        (await phone.local.rows(
          "SELECT chat_background_image FROM conversations WHERE id='role'",
        )).single['chat_background_image'],
        isNull,
      );
    },
  );

  test(
    'new local edit during a merged upload survives receipt and converges',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await editSetting(phone, 'chat_background_image', 'phone-wallpaper', 200);
      await editSetting(mac, 'voice_file', 'frozen-voice', 300);
      await phone.sync.synchronize();
      mac.remote.afterSettingPush = () =>
          editSetting(mac, 'voice_file', 'newer-voice', 400);
      await mac.sync.synchronize();
      var row = (await mac.local.rows(
        "SELECT chat_background_image,voice_file FROM conversations WHERE id='role'",
      )).single;
      expect(row['chat_background_image'], 'phone-wallpaper');
      expect(row['voice_file'], 'newer-voice');
      await mac.sync.synchronize();
      await phone.sync.synchronize();
      row = (await phone.local.rows(
        "SELECT voice_file FROM conversations WHERE id='role'",
      )).single;
      expect(row['voice_file'], 'newer-voice');
    },
  );

  test(
    'returning to the original value still publishes the newer edit time',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await editSetting(phone, 'voice_file', 'A', 100);
      await saveCloudPreference(
        phone.local.preferences,
        cloudUiModelsKey,
        jsonEncode({'default_model': 'A'}),
        atMs: 100,
      );
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await editSetting(mac, 'voice_file', 'B', 250);
      await editSetting(mac, 'voice_file', 'A', 300);
      await saveCloudPreference(
        mac.local.preferences,
        cloudUiModelsKey,
        jsonEncode({'default_model': 'B'}),
        atMs: 250,
      );
      await saveCloudPreference(
        mac.local.preferences,
        cloudUiModelsKey,
        jsonEncode({'default_model': 'A'}),
        atMs: 300,
      );
      await mac.sync.synchronize();
      await editSetting(phone, 'voice_file', 'late-B', 200);
      await saveCloudPreference(
        phone.local.preferences,
        cloudUiModelsKey,
        jsonEncode({'default_model': 'late-B'}),
        atMs: 200,
      );
      await phone.sync.synchronize();
      expect(
        (await phone.local.rows(
          "SELECT voice_file FROM conversations WHERE id='role'",
        )).single['voice_file'],
        'A',
      );
      expect(
        (jsonDecode(phone.local.preferences.get(cloudUiModelsKey) as String)
            as Map)['default_model'],
        'A',
      );
    },
  );

  test(
    'a role deleted during a merged upload is not recreated by the receipt',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await editSetting(phone, 'chat_background_image', 'phone-wallpaper', 200);
      await editSetting(mac, 'voice_file', 'mac-voice', 300);
      await phone.sync.synchronize();
      mac.remote.afterSettingPush = () async {
        await mac.local.execute(
          "DELETE FROM messages WHERE conversation_id='role'",
        );
        await mac.local.execute("DELETE FROM conversations WHERE id='role'");
      };
      await mac.sync.synchronize();
      expect(
        await mac.local.rows("SELECT id FROM conversations WHERE id='role'"),
        isEmpty,
      );
      await mac.sync.synchronize();
      await phone.sync.synchronize();
      expect(
        await phone.local.rows("SELECT id FROM conversations WHERE id='role'"),
        isEmpty,
      );
    },
  );

  test(
    'General fields never upload or replace local values while model settings sync',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await saveCloudPreference(
        phone.local.preferences,
        cloudUiModelsKey,
        jsonEncode({
          'default_model': 'phone-model',
          'text_scale_factor': 1.1,
          'is_dark_mode': false,
        }),
        atMs: 200,
      );
      await mac.local.preferences.setString(
        cloudUiModelsKey,
        jsonEncode({
          'default_model': 'initial-model',
          'text_scale_factor': 1.8,
          'is_dark_mode': true,
        }),
      );
      final outgoing = (await phone.local.external()).singleWhere(
        (doc) => doc.payload['key'] == cloudUiModelsKey,
      );
      expect(jsonDecode(outgoing.payload['json_value'] as String), {
        'default_model': 'phone-model',
      });
      await phone.sync.synchronize();
      await mac.sync.synchronize();
      final stored =
          jsonDecode(mac.local.preferences.getString(cloudUiModelsKey)!) as Map;
      expect(stored['default_model'], 'phone-model');
      expect(stored['text_scale_factor'], 1.8);
      expect(stored['is_dark_mode'], true);
      final before = mac.remote.pushRequests;
      await saveCloudPreference(
        mac.local.preferences,
        cloudUiModelsKey,
        jsonEncode({...stored, 'text_scale_factor': 2.0}),
        atMs: 500,
      );
      await mac.sync.synchronize();
      expect(mac.remote.pushRequests, before);
    },
  );

  test(
    'lost merged setting receipt retries without conflict or losing a newer local edit',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await editSetting(phone, 'chat_background_image', 'phone-wallpaper', 200);
      await editSetting(mac, 'voice_file', 'frozen-voice', 300);
      await phone.sync.synchronize();
      mac.remote.dropNextSetting = true;
      mac.remote.afterSettingPush = () =>
          editSetting(mac, 'voice_file', 'newer-voice', 400);
      await expectLater(
        mac.sync.synchronize(),
        throwsA(isA<SocketException>()),
      );
      expect(await mac.local.rows('SELECT 1 FROM cloud_outbox'), isNotEmpty);
      await mac.sync.synchronize();
      await phone.sync.synchronize();
      for (final device in [phone, mac]) {
        final row = (await device.local.rows(
          "SELECT chat_background_image,voice_file FROM conversations WHERE id='role'",
        )).single;
        expect(row['chat_background_image'], 'phone-wallpaper');
        expect(row['voice_file'], 'newer-voice');
        expect((await device.sync.previewConflicts())['conflicts'], isEmpty);
      }
    },
  );

  test(
    'an identical applied receipt inherits existing setting edit times',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await editSetting(phone, 'voice_file', 'shared-voice', 100);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await mac.local.execute('DELETE FROM cloud_setting_times');
      await mac.local.execute(
        "UPDATE cloud_versions SET local_json=NULL WHERE kind='conversations'",
      );
      await mac.local.execute(
        "UPDATE conversations SET voice_file=voice_file WHERE id='role'",
      );
      await mac.sync.synchronize();
      final times = await mac.local.settingTimes(
        'conversations',
        'role',
        'mac',
      );
      expect((times['voice_file'] as Map)['at_ms'], 100);
    },
  );

  test('confirmed source revisions are not downloaded back', () async {
    final phone = await device('phone');
    await seed(phone);
    await phone.sync.enable();
    await phone.sync.waitForMedia();
    expect(phone.remote.receivedBusinessDocuments, 0);
  });

  test(
    'scheduled rounds deliver both directions and edits wait for the next round',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      final mac = await device('mac');
      await mac.sync.enable();
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await mac.sync.waitForMedia();
      var clock = DateTime(2026, 10, 4, 9);
      CloudSyncScheduler scheduled(Device d) =>
          CloudSyncScheduler(d.local, () async {
            await d.sync.synchronize();
            return true;
          }, now: () => clock);
      final sender = scheduled(phone), receiver = scheduled(mac);
      try {
        await sender.synchronize();
        await receiver.synchronize();
        for (final (from, to, id, out, back) in [
          (phone, mac, 'phone-live', sender, receiver),
          (mac, phone, 'mac-live', receiver, sender),
        ]) {
          await from.local.db
              .into(from.local.db.messages)
              .insert(
                MessagesCompanion.insert(
                  id: id,
                  conversationId: 'role',
                  role: 'user',
                  content: 'scheduled fixture',
                  createdAt: now.millisecondsSinceEpoch,
                ),
              );
          final pushes = from.remote.pushRequests;
          await out.synchronizeIfDue();
          expect(from.remote.pushRequests, pushes, reason: 'not due yet');
          clock = clock.add(const Duration(hours: 8));
          await out.synchronizeIfDue();
          await back.synchronizeIfDue();
          await to.sync.waitForMedia();
          expect(
            (await to.local.rows('SELECT content FROM messages WHERE id=?', [
              id,
            ])).single['content'],
            'scheduled fixture',
          );
        }
      } finally {
        sender.close();
        receiver.close();
      }
    },
  );

  test(
    'idle polls only read server status and still detect a remote change',
    () async {
      final phone = await device('phone');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      phone.remote.getPaths.clear();
      final pushes = phone.remote.pushRequests;
      await phone.sync.synchronize(pollOnly: true);
      await phone.sync.waitForMedia();
      expect(phone.remote.getPaths, ['status']);
      expect(phone.remote.pushRequests, pushes);
      final mac = await device('mac');
      await mac.sync.enable();
      await mac.local.execute(
        "UPDATE messages SET content='changed elsewhere' WHERE id='text'",
      );
      await mac.sync.synchronize();
      await phone.sync.synchronize(pollOnly: true);
      expect(
        (await phone.local.rows(
          "SELECT content FROM messages WHERE id='text'",
        )).single['content'],
        'changed elsewhere',
      );
    },
  );

  test('acknowledged prefix stops at an interleaved device change', () async {
    final phone = await device('phone');
    await seed(phone);
    await phone.local.db.transaction(() async {
      for (var i = 0; i < 101; i++) {
        await phone.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
          [
            'own-$i',
            'role',
            'assistant',
            'own',
            now.millisecondsSinceEpoch + i,
          ],
        );
      }
    });
    phone.remote.afterMessagePush = () async {
      final status = await phone.remote.api.get('status');
      await phone.remote.api.post('push', {
        'protocol_version': 3,
        'epoch': status['epoch'],
        'device_id': 'interleaved-device',
        'mutations': [
          {
            'op_id': 'interleaved-operation',
            'kind': 'messages',
            'entity_id': 'foreign',
            'base_version': 0,
            'action': 'put',
            'payload_version': 1,
            'blob_ids': <String>[],
            'media_ids': <String>[],
            'payload': {
              'client_schema': 16,
              'message_snapshot_version': 1,
              'row': {
                'id': 'foreign',
                'conversation_id': 'role',
                'role': 'assistant',
                'content': 'remote edit',
                'created_at': now.millisecondsSinceEpoch,
              },
              'message_blocks': [],
              'message_projection_mappings': [],
            },
          },
        ],
      });
    };
    await phone.sync.enable();
    await phone.sync.waitForMedia();
    expect(
      (await phone.local.rows('SELECT content FROM messages WHERE id=?', [
        'foreign',
      ])).single['content'],
      'remote edit',
    );
    expect(phone.remote.receivedBusinessDocuments, greaterThan(0));
  });

  test(
    'an initialized legacy receiver enters the recent window and keeps edits',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      // Model an already-initialized installation from before indexed reads.
      await desktop.local.execute('DELETE FROM cloud_read_state');
      desktop.remote.readStages.clear();
      await desktop.local.execute(
        "UPDATE messages SET content='local preserved edit' WHERE id='text'",
      );
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(desktop.remote.readStages, contains('head'));
      expect(
        (await desktop.local.rows(
          "SELECT content FROM messages WHERE id='text'",
        )).single['content'],
        'local preserved edit',
      );
      expect(
        (await desktop.local.rows(
          'SELECT stage FROM cloud_read_state',
        )).single['stage'],
        'done',
      );
    },
  );

  test(
    'matching incoming snapshots repair stale receiver baselines without conflicts',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      await desktop.local.execute(
        "UPDATE cloud_versions SET local_json='sha256:stale-baseline' WHERE kind='messages' AND entity_id='text'",
      );
      await desktop.local.mark('messages', 'text');
      await phone.local.mark('messages', 'text');
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows(
          'SELECT count(*) n FROM cloud_versions WHERE conflict_id IS NOT NULL',
        )).single['n'],
        0,
      );
      expect(
        (await desktop.local.rows(
          'SELECT count(*) n FROM cloud_dirty',
        )).single['n'],
        0,
      );
    },
  );

  test(
    'stalled or failed media does not block messages and stays queued',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone, images: true);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      desktop.remote.downloadGate = Completer<void>();
      try {
        await desktop.sync.enable().timeout(const Duration(seconds: 5));
        expect(
          (await desktop.local.rows(
            'SELECT count(*) n FROM messages',
          )).single['n'],
          3,
        );
        expect(
          (await desktop.local.rows(
            'SELECT count(*) n FROM cloud_media_queue',
          )).single['n'],
          greaterThan(0),
        );
        desktop.remote.failDownloads = true;
      } finally {
        desktop.remote.downloadGate!.complete();
        await desktop.sync.waitForMedia();
      }
      expect(
        (await desktop.local.rows(
          'SELECT count(*) n FROM cloud_media_queue',
        )).single['n'],
        greaterThan(0),
      );
      expect(
        (await desktop.local.rows(
          'SELECT count(*) n FROM messages',
        )).single['n'],
        3,
      );
    },
  );

  test(
    'lost upload acknowledgement probes blobs without retransmission',
    () async {
      final phone = await device('phone');
      await seed(phone, images: true);
      phone.remote.dropNextUpload = true;
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      final transferred = phone.remote.uploadBatchSizes.fold<int>(
        0,
        (sum, n) => sum + n,
      );
      expect(transferred, greaterThan(0));
      expect(
        (await phone.local.rows(
          'SELECT count(*) n FROM cloud_media_queue',
        )).single['n'],
        greaterThan(0),
      );
      await phone.local.execute('UPDATE cloud_media_queue SET retry_after=0');
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      expect(
        phone.remote.uploadedDigests.length,
        phone.remote.uploadedDigests.toSet().length,
      );
      expect(
        (await phone.local.rows(
          'SELECT count(*) n FROM cloud_media_queue',
        )).single['n'],
        0,
      );
      final desktop = await device('desktop');
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows(
          'SELECT count(*) n FROM messages',
        )).single['n'],
        3,
      );
    },
  );

  test(
    'bulk history batches thumbnails and retries without uploading them again',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      final old = now.subtract(const Duration(days: 45)).millisecondsSinceEpoch;
      for (var i = 0; i < 120; i++) {
        final blocks = <Map<String, dynamic>>[];
        if (i < 40) {
          final picture = img.Image(width: 360, height: 240);
          img.fill(picture, color: img.ColorRgb8(i * 5, 100, 170));
          final file = File('${phone.local.documents.path}/bulk-$i.png')
            ..writeAsBytesSync(img.encodePng(picture));
          blocks.add({'type': 'image', 'localPath': file.path});
        }
        await phone.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
          [
            'bulk-$i',
            'role',
            'assistant',
            'bulk raw text ' * 300,
            old,
            jsonEncode({
              'blocks': blocks,
              'parameters': {'seed': i},
            }),
          ],
        );
        await phone.local.execute(
          'INSERT INTO message_blocks(id,message_id,type,status,data,sort_order,created_at) VALUES(?,?,?,?,?,?,?)',
          [
            'child-$i',
            'bulk-$i',
            'mainText',
            'success',
            jsonEncode({'text': 'child $i'}),
            0,
            old,
          ],
        );
        await phone.local.execute(
          'INSERT INTO message_projection_mappings(id,conversation_id,raw_message_id,projected_message_id,created_at) VALUES(?,?,?,?,?)',
          ['map-$i', 'role', 'bulk-$i', 'projected-$i', old],
        );
      }
      phone.remote.dropNextMessage = true;
      await expectLater(phone.sync.enable(), throwsA(isA<SocketException>()));
      expect(phone.remote.uploadBatchSizes, isEmpty);
      expect(
        (await phone.local.rows(
          'SELECT max(length(local_json)) AS n FROM cloud_outbox',
        )).single['n'],
        71,
      );
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      expect(
        phone.remote.uploadBatchSizes.fold<int>(0, (sum, n) => sum + n),
        40,
      );
      expect(phone.remote.uploadBatchSizes.every((n) => n <= 32), isTrue);
      expect(phone.remote.pushRequests, lessThanOrEqualTo(9));
      expect(
        phone.remote.publishedKinds.intersection({
          'message_blocks',
          'message_projection_mappings',
        }),
        isEmpty,
      );
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows(
          'SELECT count(*) AS n FROM messages',
        )).single['n'],
        121,
      );
      expect(
        (await desktop.local.rows(
          'SELECT raw_payload FROM messages WHERE id=?',
          ['bulk-119'],
        )).single['raw_payload'],
        jsonEncode({
          'blocks': [],
          'parameters': {'seed': 119},
        }),
      );
      expect((await desktop.media.records().toList()).length, 40);
      expect(desktop.remote.peakDownloads, inInclusiveRange(2, 3));
      expect(
        (await desktop.local.rows(
          'SELECT count(*) AS n FROM message_blocks',
        )).single['n'],
        120,
      );
      expect(
        (await desktop.local.rows(
          "SELECT max(length(cloud_json)) AS n FROM cloud_versions WHERE kind='messages'",
        )).single['n'],
        lessThan(1500),
        reason:
            'Version tracking must not duplicate complete raw message snapshots',
      );
      expect(
        (await desktop.local.rows(
          'SELECT count(*) AS n FROM message_projection_mappings',
        )).single['n'],
        120,
      );

      // Different decoders may produce different thumbnail bytes for the same
      // original. The server keeps the first thumbnail; its digest and the
      // publisher's cached file must still agree after the additive merge.
      final original = await phone.media.register(
        '${phone.local.documents.path}/bulk-0.png',
        createdAtMs: old,
      );
      final canonicalThumbnail = original.asset.thumbnailBlob;
      final alternate = img.encodeJpg(img.Image(width: 10, height: 10));
      await File(original.thumbnailPath!).writeAsBytes(alternate);
      await phone.media.save(
        LocalMedia(
          MediaAsset.fromJson({
            ...original.asset.toJson(),
            'thumbnail_blob': sha256.convert(alternate).toString(),
          }),
          originalPath: original.originalPath,
          thumbnailPath: original.thumbnailPath,
        ),
      );
      await phone.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'edited after a decoder change',
        'bulk-0',
      ]);
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      final reconciled = (await phone.media.load(original.asset.id))!;
      expect(reconciled.asset.thumbnailBlob, canonicalThumbnail);
      expect(
        sha256
            .convert(await File(reconciled.thumbnailPath!).readAsBytes())
            .toString(),
        canonicalThumbnail,
      );
      await phone.local.execute('DELETE FROM message_blocks WHERE id=?', [
        'child-0',
      ]);
      await phone.local.execute(
        'DELETE FROM message_projection_mappings WHERE id=?',
        ['map-0'],
      );
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        await desktop.local.rows('SELECT id FROM message_blocks WHERE id=?', [
          'child-0',
        ]),
        isEmpty,
      );
      expect(
        await desktop.local.rows(
          'SELECT id FROM message_projection_mappings WHERE id=?',
          ['map-0'],
        ),
        isEmpty,
      );
      final legacyRow = Map<String, dynamic>.from(
        (await phone.local.read('messages', 'bulk-119'))!.payload['row'] as Map,
      )..['id'] = 'legacy';
      final legacyChild =
          Map<String, dynamic>.from(
              (await phone.local.rows(
                'SELECT * FROM message_blocks WHERE id=?',
                ['child-1'],
              )).single,
            )
            ..['id'] = 'legacy-child'
            ..['message_id'] = 'legacy';
      final status = await phone.remote.get('status');
      await phone.remote.post('push', {
        'protocol_version': 3,
        'epoch': status['epoch'],
        'device_id': 'previous-version',
        'mutations': [
          for (final entry in [
            ('messages', 'legacy', legacyRow),
            ('message_blocks', 'legacy-child', legacyChild),
          ])
            {
              'op_id': 'legacy-${entry.$1}',
              'kind': entry.$1,
              'entity_id': entry.$2,
              'base_version': 0,
              'payload': {'client_schema': 16, 'row': entry.$3},
            },
        ],
      });
      final pushesBeforeLegacyPull = desktop.remote.pushRequests;
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        desktop.remote.pushRequests,
        pushesBeforeLegacyPull,
        reason:
            'receiving legacy child rows must not look like a local message edit',
      );
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await phone.local.execute('UPDATE message_blocks SET data=? WHERE id=?', [
        jsonEncode({'text': 'updated legacy child'}),
        'legacy-child',
      ]);
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows(
          'SELECT data FROM message_blocks WHERE id=?',
          ['legacy-child'],
        )).single['data'],
        jsonEncode({'text': 'updated legacy child'}),
      );
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );

  test(
    'phone to desktop preserves raw history, all settings and presets, old thumbnails and recent originals',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone, images: true);
      await phone.local.preferences.setString(
        'aicove.ui_models.v1',
        '{"theme":"dark","font_size":19,"providers":[{"key":"fixture-key"}]}',
      );
      for (final plugin in [
        'tts',
        'memory',
        'image',
        'sticker',
        'trigger',
        'time_awareness',
      ]) {
        await phone.local.preferences.setString(
          'aicove.plugins.$plugin.config',
          '{"enabled":true,"fixture":"$plugin"}',
        );
      }
      await phone.local.preferences.setString(
        'aicove.cloud.device_id',
        'do-not-copy',
      );
      final preset = File(
        '${phone.local.documents.path}/aicove/sillytavern_presets/preset.json',
      );
      await preset.parent.create(recursive: true);
      await preset.writeAsString('{"raw":"unchanged"}');
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      expect(
        await desktop.local.rows(
          'SELECT content,raw_payload FROM messages WHERE id=?',
          ['text'],
        ),
        await phone.local.rows(
          'SELECT content,raw_payload FROM messages WHERE id=?',
          ['text'],
        ),
      );
      expect(await desktop.local.rows('SELECT COUNT(*) AS n FROM messages'), [
        {'n': 3},
      ]);
      expect(
        jsonDecode(
          desktop.local.preferences.get('aicove.ui_models.v1') as String,
        ),
        jsonDecode(
          phone.local.preferences.get('aicove.ui_models.v1') as String,
        ),
      );
      for (final plugin in [
        'tts',
        'memory',
        'image',
        'sticker',
        'trigger',
        'time_awareness',
      ]) {
        expect(
          desktop.local.preferences.get('aicove.plugins.$plugin.config'),
          phone.local.preferences.get('aicove.plugins.$plugin.config'),
        );
      }
      expect(desktop.local.preferences.get('aicove.cloud.device_id'), isNull);
      expect(
        await File(
          '${desktop.local.documents.path}/aicove/sillytavern_presets/preset.json',
        ).readAsString(),
        '{"raw":"unchanged"}',
      );
      for (final recent in [false, true]) {
        final row = (await desktop.local.rows(
          'SELECT data FROM message_blocks WHERE id=?',
          ['block-${recent ? 'recent' : 'old'}'],
        )).single;
        final block = jsonDecode(row['data'] as String);
        final id = mediaIdFromReference(block['localPath'] as String)!;
        final record = (await desktop.media.load(id))!;
        expect(record.thumbnailPath, isNotNull);
        expect(record.originalPath != null, recent);
        final input = [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': record.asset.reference},
              },
            ],
          },
        ];
        if (recent) {
          final resolved = await resolveModelMedia(input, store: desktop.media);
          expect(
            (resolved.single['content'] as List).single['image_url']['url'],
            startsWith('data:image/png;base64,'),
          );
        } else {
          await expectLater(
            resolveModelMedia(input, store: desktop.media),
            throwsA(isA<OriginalMediaUnavailable>()),
          );
          expect(await (await phone.media.original(id)).exists(), true);
        }
      }
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );

  test(
    'lost response is retried exactly once and later edits propagate both directions',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      phone.remote.dropNextMessage = true;
      await expectLater(phone.sync.enable(), throwsA(isA<SocketException>()));
      expect(
        await phone.local.rows('SELECT * FROM cloud_outbox'),
        hasLength(2),
      );
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      expect(await desktop.local.rows('SELECT COUNT(*) AS n FROM messages'), [
        {'n': 1},
      ]);
      await desktop.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'edited on desktop',
        'text',
      ]);
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      expect(
        (await phone.local.rows('SELECT content FROM messages WHERE id=?', [
          'text',
        ])).single['content'],
        'edited on desktop',
      );
      expect((await phone.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );

  test(
    'simultaneous edits retain local and cloud versions instead of overwriting',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      await phone.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'phone edit',
        'text',
      ]);
      await desktop.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'desktop edit',
        'text',
      ]);
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows('SELECT content FROM messages WHERE id=?', [
          'text',
        ])).single['content'],
        'desktop edit',
      );
      expect(
        (await desktop.remote.get('conflicts'))['conflicts'],
        hasLength(1),
      );
      expect(
        (await desktop.local.rows(
          'SELECT conflict_id FROM cloud_versions WHERE kind=? AND entity_id=?',
          ['messages', 'text'],
        )).single['conflict_id'],
        isNotNull,
      );
      await phone.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'newer phone edit',
        'text',
      ]);
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      expect(
        (await desktop.local.rows('SELECT content FROM messages WHERE id=?', [
          'text',
        ])).single['content'],
        'desktop edit',
      );
      final preview = await desktop.sync.previewConflicts();
      await desktop.sync.resolveConflict(
        preview,
        (preview['conflicts'] as List).single['conflict_id'] as String,
        incoming: false,
      );
      expect(
        (await desktop.local.rows('SELECT content FROM messages WHERE id=?', [
          'text',
        ])).single['content'],
        'newer phone edit',
      );
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );
  test('each device publishes its own name without conflicts', () async {
    final phone = await device('phone'), desktop = await device('desktop');
    await seed(phone);
    await phone.sync.enable();
    await desktop.sync.enable();
    for (final (d, name) in [
      (phone, 'OnePlus 13T'),
      (desktop, 'MacBook Pro'),
    ]) {
      await d.local.preferences.setString(lanNameKey, name);
      await publishDeviceName(d.local.preferences, d.sync.media.deviceId);
    }
    for (var round = 0; round < 2; round++) {
      await phone.sync.synchronize();
      await desktop.sync.synchronize();
    }
    final expected = {
      phone.sync.media.deviceId: 'OnePlus 13T',
      desktop.sync.media.deviceId: 'MacBook Pro',
    };
    expect(readDeviceNames(phone.local.preferences), expected);
    expect(readDeviceNames(desktop.local.preferences), expected);
    expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
  });
  Future<void> lanApply(Device d, String content, Duration relayIn) async {
    await d.local.execute('UPDATE cloud_client_state SET suspended=1');
    await d.local.execute("UPDATE messages SET content=? WHERE id='text'", [
      content,
    ]);
    await d.local.execute('UPDATE cloud_client_state SET suspended=0');
    await d.local.markRelay(
      'messages',
      'text',
      DateTime.now().add(relayIn).millisecondsSinceEpoch,
    );
  }

  Future<String> cloudText(Device d) async =>
      (await d.local.rows(
            "SELECT content FROM messages WHERE id='text'",
          )).single['content']
          as String;

  test(
    'a LAN-received edit its origin already uploaded is not uploaded again',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      await phone.local.execute(
        "UPDATE messages SET content='from phone' WHERE id='text'",
      );
      await phone.sync.synchronize();
      await lanApply(desktop, 'from phone', const Duration(hours: 24));
      final pushes = desktop.remote.pushRequests;
      await desktop.sync.synchronize();
      expect(desktop.remote.pushRequests, pushes);
      expect(
        await desktop.local.rows(
          "SELECT 1 FROM cloud_dirty WHERE kind='messages' AND entity_id='text'",
        ),
        isEmpty,
      );
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );

  test(
    'a LAN-received edit waits for its origin, then is relayed as fallback',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone);
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      await lanApply(
        desktop,
        'phone stayed offline',
        const Duration(hours: 24),
      );
      final pushes = desktop.remote.pushRequests;
      await desktop.sync.synchronize();
      expect(desktop.remote.pushRequests, pushes, reason: 'origin may upload');
      await lanApply(
        desktop,
        'phone stayed offline',
        -const Duration(minutes: 1),
      );
      await desktop.sync.synchronize();
      expect(desktop.remote.pushRequests, greaterThan(pushes));
      await phone.sync.synchronize();
      expect(await cloudText(phone), 'phone stayed offline');

      // An own edit after a LAN edit is uploaded immediately.
      await lanApply(desktop, 'lan again', const Duration(hours: 24));
      await desktop.local.execute(
        "UPDATE messages SET content='desktop own' WHERE id='text'",
      );
      await desktop.sync.synchronize();
      await phone.sync.synchronize();
      expect(await cloudText(phone), 'desktop own');
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );

  test('choosing a device resolves all its conflicts in one batch', () async {
    final phone = await device('phone'), desktop = await device('desktop');
    await seed(phone);
    await phone.local.execute(
      'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
      ['text2', 'role', 'assistant', 'second', 0, '{}'],
    );
    await phone.sync.enable();
    await phone.sync.waitForMedia();
    await desktop.sync.enable();
    await desktop.sync.waitForMedia();
    for (final id in ['text', 'text2']) {
      await phone.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'phone $id',
        id,
      ]);
      await desktop.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'desktop $id',
        id,
      ]);
    }
    await phone.sync.synchronize();
    await phone.sync.waitForMedia();
    await desktop.sync.synchronize();
    await desktop.sync.waitForMedia();
    final preview = await desktop.sync.previewConflicts();
    final conflicts = (preview['conflicts'] as List).cast<Map>();
    expect(conflicts, hasLength(2));
    final progress = <int>[];
    await desktop.sync.resolveConflicts(preview, {
      for (final c in conflicts)
        c['conflict_id'] as String:
            c['device_id'] == desktop.sync.media.deviceId,
    }, onProgress: (done, _) => progress.add(done));
    expect(progress, [1, 2]);
    expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    await phone.sync.synchronize();
    await phone.sync.waitForMedia();
    expect(
      (await phone.local.rows(
        'SELECT id,content FROM messages ORDER BY id',
      )).map((row) => row['content']),
      ['desktop text', 'desktop text2'],
    );
  });
  test(
    'voice sample files transfer in full and an old settings image keeps its identity after download',
    () async {
      final phone = await device('phone'), desktop = await device('desktop');
      await seed(phone, images: true);
      final voice = File('${phone.local.documents.path}/voice.wav')
        ..writeAsBytesSync(utf8.encode('RIFF0000WAVEfixture'));
      final embedded =
          'data:audio/wav;base64,${base64Encode(await voice.readAsBytes())}';
      await phone.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [
          jsonEncode({
            'rawReplyText': '<tts>unchanged text</tts>',
            'toolAudioResults': [
              {'audioUrl': embedded, 'text': 'unchanged text'},
            ],
            'supplementInsertOps': [
              {'audioUrl': embedded, 'textCharsBefore': 7},
            ],
            'projectedMessages': [
              {
                'blocks': [
                  {'type': 'audio', 'url': embedded},
                ],
              },
            ],
            'parameters': {'seed': 42},
          }),
          'text',
        ],
      );
      await phone.local.preferences.setString(
        'aicove.plugins.tts.config',
        jsonEncode({
          'voicePresets': [
            {
              'localAudioPath': voice.path,
              'promptText': 'reference text',
              'synthesis': {'provider': 'fixture'},
            },
          ],
        }),
      );
      await phone.local.preferences.setString(
        'aicove.ui_models.v1',
        jsonEncode({
          'chatBackgroundImage': '${phone.local.documents.path}/old.png',
          'textScaleFactor': 1.25,
        }),
      );
      await phone.sync.enable();
      await phone.sync.waitForMedia();
      await desktop.sync.enable();
      await desktop.sync.waitForMedia();
      final settings = jsonDecode(
        desktop.local.preferences.get('aicove.ui_models.v1') as String,
      );
      expect(
        await File(settings['chatBackgroundImage'] as String).exists(),
        true,
      );
      expect(
        await File(settings['chatBackgroundImage'] as String).readAsBytes(),
        await File('${phone.local.documents.path}/old.png').readAsBytes(),
      );
      for (final target in [phone, desktop]) {
        final raw =
            (await target.local.rows(
                  'SELECT raw_payload FROM messages WHERE id=?',
                  ['text'],
                )).single['raw_payload']
                as String;
        expect(raw, isNot(contains('data:audio/')));
        final payload = jsonDecode(raw);
        final stored = payload['toolAudioResults'][0]['audioUrl'] as String;
        expect(payload['supplementInsertOps'][0]['audioUrl'], stored);
        expect(payload['projectedMessages'][0]['blocks'][0]['url'], stored);
        expect(await File(stored).readAsBytes(), await voice.readAsBytes());
        expect(payload['parameters'], {'seed': 42});
      }
      final config = jsonDecode(
        desktop.local.preferences.get('aicove.plugins.tts.config') as String,
      );
      final path = config['voicePresets'][0]['localAudioPath'] as String;
      expect(await File(path).readAsBytes(), await voice.readAsBytes());
      final mediaBefore = (await desktop.media.records().toList())
          .map((record) => record.asset.id)
          .toSet();
      settings['textScaleFactor'] = 1.5;
      await desktop.local.preferences.setString(
        'aicove.ui_models.v1',
        jsonEncode(settings),
      );
      await desktop.sync.synchronize();
      await desktop.sync.waitForMedia();
      await phone.sync.synchronize();
      await phone.sync.waitForMedia();
      final updated = jsonDecode(
        phone.local.preferences.get('aicove.ui_models.v1') as String,
      );
      expect(updated['textScaleFactor'], 1.5);
      expect(
        await File(updated['chatBackgroundImage'] as String).readAsBytes(),
        await File('${phone.local.documents.path}/old.png').readAsBytes(),
      );
      expect(
        (await desktop.media.records().toList()).map(
          (record) => record.asset.id,
        ),
        unorderedEquals(mediaBefore),
      );
      expect((await desktop.remote.get('conflicts'))['conflicts'], isEmpty);
    },
  );
}
