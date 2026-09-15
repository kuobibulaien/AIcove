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

class MemoryPreferences implements SharedPreferences {
  final values = <String, Object>{};
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Object? get(String key) => values[key];
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
  bool dropNextMessage = false;
  int pushRequests = 0;
  int activeDownloads = 0, peakDownloads = 0;
  final uploadBatchSizes = <int>[];
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
  ]) => api.get(path, query);
  @override
  Future<void> upload(String digest, File file) => api.upload(digest, file);
  @override
  Future<void> uploadBatch(Map<String, File> files) {
    uploadBatchSizes.add(files.length);
    return api.uploadBatch(files);
  }

  @override
  Future<void> download(String digest, File file) async {
    activeDownloads++;
    if (activeDownloads > peakDownloads) peakDownloads = activeDownloads;
    try {
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
  late Process server;
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
    server = await Process.start(python, [
      '$backend/tests/serve_flutter_fixture.py',
    ], workingDirectory: backend);
    server.stderr.transform(utf8.decoder).listen((text) {
      stderr.write(text);
    });
    final ready = Completer<String>();
    server.stdout
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
    server.kill();
    await server.exitCode;
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
      expect(phone.remote.uploadBatchSizes, [40]);
      expect(
        (await phone.local.rows(
          'SELECT max(length(local_json)) AS n FROM cloud_outbox',
        )).single['n'],
        71,
      );
      await phone.sync.synchronize();
      expect(phone.remote.uploadBatchSizes, [40]);
      expect(phone.remote.pushRequests, lessThanOrEqualTo(5));
      expect(
        phone.remote.publishedKinds.intersection({
          'message_blocks',
          'message_projection_mappings',
        }),
        isEmpty,
      );
      await desktop.sync.enable();
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
      await desktop.sync.synchronize();
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
      expect(
        desktop.remote.pushRequests,
        pushesBeforeLegacyPull,
        reason:
            'receiving legacy child rows must not look like a local message edit',
      );
      await phone.sync.synchronize();
      await phone.local.execute('UPDATE message_blocks SET data=? WHERE id=?', [
        jsonEncode({'text': 'updated legacy child'}),
        'legacy-child',
      ]);
      await phone.sync.synchronize();
      await desktop.sync.synchronize();
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
      await desktop.sync.enable();
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
        desktop.local.preferences.get('aicove.ui_models.v1'),
        phone.local.preferences.get('aicove.ui_models.v1'),
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
      await desktop.sync.enable();
      expect(await desktop.local.rows('SELECT COUNT(*) AS n FROM messages'), [
        {'n': 1},
      ]);
      await desktop.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'edited on desktop',
        'text',
      ]);
      await desktop.sync.synchronize();
      await phone.sync.synchronize();
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
      await desktop.sync.enable();
      await phone.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'phone edit',
        'text',
      ]);
      await desktop.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'desktop edit',
        'text',
      ]);
      await phone.sync.synchronize();
      await desktop.sync.synchronize();
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
      await desktop.sync.synchronize();
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
      await desktop.sync.enable();
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
      await phone.sync.synchronize();
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
