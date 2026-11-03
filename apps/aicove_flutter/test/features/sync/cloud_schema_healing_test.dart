import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/sync/cloud_tracking.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';

import 'lan_repository_test.dart' show LanTestDevice, lanTestDevice, seedLan;

class _Remote implements CloudRemote {
  final incoming = <Map<String, dynamic>>[];
  final sent = <Map<String, dynamic>>[];
  int sequence = 100;
  bool failPush = false;
  Future<void> Function()? beforePull;

  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    if (path == 'status') {
      return {
        'epoch': 'fixture',
        'cursor': sequence,
        'media_version': 1,
        'message_snapshot_version': 1,
        'media_usage_version': 1,
      };
    }
    if (path == 'pull') {
      final callback = beforePull;
      beforePull = null;
      await callback?.call();
      final changes = incoming.toList();
      incoming.clear();
      return {
        'through': sequence,
        'next_cursor': sequence,
        'has_more': false,
        'changes': changes,
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path != 'push') throw StateError('Unexpected POST $path');
    if (failPush) throw const SocketException('frozen fixture');
    final results = <Map<String, dynamic>>[];
    for (final raw in body['mutations'] as List) {
      final m = Map<String, dynamic>.from(raw as Map);
      sent.add(m);
      results.add({
        'op_id': m['op_id'],
        'status': 'applied',
        'document': {
          'kind': m['kind'],
          'entity_id': m['entity_id'],
          'version': (m['base_version'] as int) + 1,
          'seq': ++sequence,
          'deleted': m['action'] == 'delete',
          'payload_version': 1,
          'payload': m['payload'],
          'blob_ids': m['blob_ids'],
          'media_ids': m['media_ids'],
        },
      });
    }
    return {'results': results};
  }

  @override
  void close() {}
  @override
  Future<void> upload(String digest, File file) async =>
      throw StateError('Unexpected upload');
  @override
  Future<void> uploadBatch(Map<String, File> files) async =>
      throw StateError('Unexpected upload');
  @override
  Future<void> download(String digest, File file) async =>
      throw StateError('Unexpected download');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LanTestDevice device;
  late _Remote remote;
  late CloudSyncEngine engine;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('cloud-schema-healing-');
    device = await lanTestDevice(root, 'local');
    remote = _Remote();
    engine = CloudSyncEngine(device.local, remote, device.media, 'fixture');
    await device.local.execute(
      "UPDATE cloud_client_state SET enabled=1,initialized=1,mode='receive',epoch='fixture',account_key='fixture' WHERE id=1",
    );
    await seedLan(device);
    await device.local.prepareMessageSnapshots();
    await device.local.execute('DELETE FROM cloud_dirty');
  });

  tearDown(() async {
    await engine.waitForMedia();
    engine.close();
    await device.media.close();
    await device.local.db.close();
    await root.delete(recursive: true);
  });

  Future<Map<String, dynamic>> document({
    int version = 2,
    int schema = kCloudRowSchema - 1,
    String kind = 'messages',
    String id = 'message',
  }) async => {
    'kind': kind,
    'entity_id': id,
    'version': version,
    'seq': ++remote.sequence,
    'deleted': false,
    'payload_version': 1,
    'payload': {
      ...(await device.local.read(kind, id))!.payload,
      'client_schema': schema,
      'setting_times_version': 1,
      'setting_times': <String, dynamic>{},
    },
    'blob_ids': <String>[],
    'media_ids': <String>[],
  };

  Future<void> remember(
    Map<String, dynamic> doc, {
    String? fingerprint,
    String? conflict = 'old-conflict',
  }) async {
    final current = (await device.local.read(
      doc['kind'] as String,
      doc['entity_id'] as String,
    ))!;
    await device.local
        .execute('INSERT OR REPLACE INTO cloud_versions VALUES(?,?,?,?,?,?)', [
          doc['kind'],
          doc['entity_id'],
          doc['version'],
          fingerprint ?? current.localJson,
          canonicalJson(doc),
          conflict,
        ]);
  }

  Future<Map<String, dynamic>> version([String id = 'message']) async =>
      (await device.local.rows(
        'SELECT * FROM cloud_versions WHERE entity_id=?',
        [id],
      )).single;

  test('local fingerprint ignores only the top-level schema', () {
    const a = CloudLocalDocument('messages', 'm', {
      'client_schema': 1,
      'row': {'client_schema': 7},
    });
    const b = CloudLocalDocument('messages', 'm', {
      'client_schema': 2,
      'row': {'client_schema': 7},
    });
    const c = CloudLocalDocument('messages', 'm', {
      'client_schema': 2,
      'row': {'client_schema': 8},
    });
    expect(a.localJson, b.localJson);
    expect(a.localJson, isNot(c.localJson));
  });

  for (final dirty in [false, true]) {
    for (final schema in [kCloudRowSchema, kCloudRowSchema - 1]) {
      test(
        'legacy baseline migrates without upload: dirty=$dirty schema=$schema',
        () async {
          final current = (await device.local.read('messages', 'message'))!;
          final old =
              'sha256:${cloudObjectId(canonicalJson({...current.payload, 'client_schema': schema}))}';
          final doc = await document(version: 1, schema: schema);
          await remember(doc, fingerprint: old);
          if (dirty) await device.local.mark('messages', 'message');
          final before = await device.local.rows('SELECT * FROM cloud_dirty');
          await engine.synchronize();
          expect((await version())['local_json'], current.localJson);
          expect(await device.local.rows('SELECT * FROM cloud_dirty'), before);
          expect(remote.sent, isEmpty);
          final migrations = await device.local.rows(
            'SELECT name FROM cloud_local_migrations',
          );
          expect(
            migrations.any(
              (row) => row['name'] == 'cloud_content_fingerprint_v1',
            ),
            true,
          );
          await engine.synchronize();
          expect((await version())['local_json'], current.localJson);
          expect(remote.sent, isEmpty);
        },
      );
    }
  }

  test(
    'migration preserves a real offline edit even with a dirty conflict',
    () async {
      final old = (await device.local.read('messages', 'message'))!;
      final baseline = 'sha256:${cloudObjectId(canonicalJson(old.payload))}';
      await remember(await document(version: 1), fingerprint: baseline);
      await device.local.execute(
        "UPDATE messages SET content='offline edit' WHERE id='message'",
      );
      final before = await device.local.rows('SELECT * FROM cloud_dirty');
      await engine.synchronize();
      expect((await version())['local_json'], baseline);
      expect(await device.local.rows('SELECT * FROM cloud_dirty'), before);
      expect(remote.sent, isEmpty);
    },
  );

  test(
    'compact message receipt migrates an old schema without hiding edits',
    () async {
      final current = (await device.local.read('messages', 'message'))!;
      final old =
          'sha256:${cloudObjectId(canonicalJson({...current.payload, 'client_schema': kCloudRowSchema - 1}))}';
      final doc = await document(version: 1);
      doc['payload'] = {'message_snapshot_version': 1};
      await remember(doc, fingerprint: old);
      await device.local.mark('messages', 'message');
      await device.local.prepareSchemaFingerprints();
      expect((await version())['local_json'], current.localJson);
      final before = await device.local.rows('SELECT * FROM cloud_dirty');
      await device.local.execute(
        "UPDATE messages SET content='later offline edit' WHERE id='message'",
      );
      await device.local.prepareSchemaFingerprints();
      expect((await version())['local_json'], current.localJson);
      expect(
        await device.local.rows('SELECT * FROM cloud_dirty'),
        isNot(before),
      );
    },
  );

  test(
    'tombstone can consume a business row already cached in the same inbox batch',
    () async {
      final doc = await document(version: 3);
      await remember(doc, fingerprint: 'stale baseline');
      await device.local.mark('messages', 'message');
      remote.incoming.add(doc);
      remote.incoming.add({
        'kind': '_conflicts',
        'entity_id': 'old-conflict',
        'seq': ++remote.sequence,
        'version': 2,
        'deleted': true,
        'payload': {},
        'blob_ids': <String>[],
        'media_ids': <String>[],
      });
      await engine.synchronize();
      expect((await version())['conflict_id'], isNull);
      expect((await version())['version'], 3);
      expect(await device.local.rows('SELECT * FROM cloud_dirty'), isEmpty);
      expect(await device.local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      expect(remote.sent, isEmpty);
    },
  );

  test(
    'legacy raw message baseline still upgrades to a complete snapshot',
    () async {
      await device.local.execute(
        "DELETE FROM cloud_local_migrations WHERE name='message_snapshots_v1'",
      );
      final row = (await device.local.read(
        'messages',
        'message',
        includeRelated: false,
      ))!;
      await remember(
        await document(version: 1),
        fingerprint: canonicalJson({
          ...row.payload,
          'client_schema': kCloudRowSchema - 1,
        }),
      );
      await device.local.prepareMessageSnapshots();
      expect(
        (await version())['local_json'],
        (await device.local.read('messages', 'message'))!.localJson,
      );
    },
  );

  test(
    'fingerprint migration spans batches and preserves frozen operations',
    () async {
      await device.local.db.transaction(() async {
        for (var i = 0; i < 205; i++) {
          final id = 'migration-$i';
          await device.local.execute(
            "INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,'role','user','same',1)",
            [id],
          );
          final current = (await device.local.read('messages', id))!;
          final old =
              'sha256:${cloudObjectId(canonicalJson({...current.payload, 'client_schema': kCloudRowSchema - 1}))}';
          final doc = {
            'kind': 'messages',
            'entity_id': id,
            'version': 1,
            'seq': i + 1,
            'deleted': false,
            'payload': {'message_snapshot_version': 1},
          };
          await remember(doc, fingerprint: i == 0 ? current.localJson : old);
        }
        await device.local.execute(
          "UPDATE messages SET content='offline edit' WHERE id='migration-7'",
        );
        await device.local.execute(
          'INSERT INTO cloud_outbox VALUES(?,?,?,?,?,?)',
          ['frozen', 'messages', 'migration-3', 1, '{}', 'frozen baseline'],
        );
      });
      final beforeDirty = await device.local.rows(
        'SELECT * FROM cloud_dirty ORDER BY entity_id',
      );
      final beforeOutbox = await device.local.rows(
        'SELECT * FROM cloud_outbox',
      );
      final edited = await version('migration-7');
      await device.local.prepareSchemaFingerprints();
      for (var i = 0; i < 205; i++) {
        final known = await version('migration-$i');
        expect(
          known['local_json'],
          i == 7
              ? edited['local_json']
              : (await device.local.read(
                  'messages',
                  'migration-$i',
                ))!.localJson,
        );
      }
      expect(
        await device.local.rows('SELECT * FROM cloud_dirty ORDER BY entity_id'),
        beforeDirty,
      );
      expect(
        await device.local.rows('SELECT * FROM cloud_outbox'),
        beforeOutbox,
      );
      await device.local.prepareSchemaFingerprints();
      expect(await version('migration-7'), edited);
    },
  );

  test(
    'migrated clean baseline accepts a real remote update without upload',
    () async {
      final current = (await device.local.read('messages', 'message'))!;
      final old =
          'sha256:${cloudObjectId(canonicalJson({...current.payload, 'client_schema': kCloudRowSchema - 1}))}';
      final summary = await document(version: 1);
      summary['payload'] = {'message_snapshot_version': 1};
      await remember(summary, fingerprint: old, conflict: null);
      final incoming = await document(version: 2);
      incoming['payload']['row']['content'] = 'real remote update';
      remote.incoming.add(incoming);
      await engine.synchronize();
      expect(
        (await device.local.read(
          'messages',
          'message',
        ))!.payload['row']['content'],
        'real remote update',
      );
      expect((await version())['version'], 2);
      expect(await device.local.rows('SELECT * FROM cloud_dirty'), isEmpty);
      expect(await device.local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      expect(remote.sent, isEmpty);
    },
  );

  test(
    'matching settings at the known version inherit clocks without applying a row',
    () async {
      final old = await document(version: 3, kind: 'conversations', id: 'role');
      await remember(old, fingerprint: 'stale baseline');
      await device.local.mark('conversations', 'role');
      final incoming = await document(
        version: 3,
        kind: 'conversations',
        id: 'role',
      );
      incoming['payload']['setting_times'] = {
        'title': {'at_ms': 17, 'device_id': 'remote'},
      };
      remote.incoming.add(incoming);
      final localBefore = (await device.local.read(
        'conversations',
        'role',
      ))!.payload;
      await engine.synchronize();
      final known = await version('role');
      expect(known['conflict_id'], isNull);
      expect(known['version'], 3);
      expect(
        (jsonDecode(known['cloud_json'] as String)
            as Map)['payload']['setting_times']['title']['at_ms'],
        17,
      );
      expect(
        await device.local.settingTimes('conversations', 'role', 'local'),
        {
          'title': {'at_ms': 17, 'device_id': 'remote'},
        },
      );
      expect(
        (await device.local.read('conversations', 'role'))!.payload,
        localBefore,
      );
      expect(await device.local.rows('SELECT * FROM cloud_dirty'), isEmpty);
      expect(await device.local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      expect(remote.sent, isEmpty);
    },
  );

  test('newer setting clocks never retire different local content', () async {
    await remember(
      await document(version: 1, kind: 'conversations', id: 'role'),
    );
    await device.local.execute(
      "UPDATE conversations SET title='offline title' WHERE id='role'",
    );
    final incoming = await document(
      version: 2,
      kind: 'conversations',
      id: 'role',
    );
    incoming['payload']['row']['title'] = 'different remote title';
    incoming['payload']['setting_times'] = {
      'title': {'at_ms': 9999999999999, 'device_id': 'remote'},
    };
    remote.incoming.add(incoming);
    await engine.synchronize();
    expect((await version('role'))['conflict_id'], 'old-conflict');
    expect(
      (await device.local.read(
        'conversations',
        'role',
      ))!.payload['row']['title'],
      'offline title',
    );
    expect(await device.local.rows('SELECT * FROM cloud_dirty'), hasLength(1));
    expect(remote.sent, isEmpty);
  });

  for (final dirty in [false, true]) {
    test(
      'matching conflicted inbox advances baseline and consumes inbox: dirty=$dirty',
      () async {
        final old = await document(version: 1);
        await remember(old, fingerprint: 'stale baseline');
        if (dirty) await device.local.mark('messages', 'message');
        remote.incoming.add(await document(version: 4));
        await engine.synchronize();
        final known = await version();
        expect(known['version'], 4);
        expect(known['conflict_id'], isNull);
        expect(
          known['local_json'],
          (await device.local.read('messages', 'message'))!.localJson,
        );
        expect(await device.local.rows('SELECT * FROM cloud_inbox'), isEmpty);
        expect(await device.local.rows('SELECT * FROM cloud_dirty'), isEmpty);
        expect(remote.sent, isEmpty);
      },
    );
  }

  test(
    'conflict tombstone heals dirty state without a new business inbox document',
    () async {
      await remember(await document(version: 3), fingerprint: 'stale baseline');
      await device.local.mark('messages', 'message');
      remote.incoming.add({
        'kind': '_conflicts',
        'entity_id': 'old-conflict',
        'seq': ++remote.sequence,
        'version': 2,
        'deleted': true,
        'payload': {},
        'blob_ids': <String>[],
        'media_ids': <String>[],
      });
      await engine.synchronize();
      expect((await version())['conflict_id'], isNull);
      expect(
        (await version())['local_json'],
        (await device.local.read('messages', 'message'))!.localJson,
      );
      expect(await device.local.rows('SELECT * FROM cloud_dirty'), isEmpty);
      expect(await device.local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      expect(remote.sent, isEmpty);
    },
  );

  test(
    'different business content and stale inbox never retire a conflict',
    () async {
      await remember(await document(version: 5));
      await device.local.mark('messages', 'message');
      final incoming = await document(version: 6);
      incoming['payload'] = {
        ...incoming['payload'] as Map,
        'row': {...incoming['payload']['row'] as Map, 'content': 'remote edit'},
      };
      remote.incoming.add(incoming);
      await engine.synchronize();
      expect((await version())['conflict_id'], 'old-conflict');
      expect(
        await device.local.rows('SELECT * FROM cloud_dirty'),
        hasLength(1),
      );
      remote.incoming.add(await document(version: 4));
      await engine.synchronize();
      expect((await version())['version'], 5);
      expect((await version())['conflict_id'], 'old-conflict');
      expect(remote.sent, isEmpty);
    },
  );

  for (final incompatible in ['schema', 'column']) {
    test(
      'matching shortcut retains $incompatible compatibility guard',
      () async {
        await remember(await document(version: 1));
        await device.local.mark('messages', 'message');
        final incoming = await document(
          version: 2,
          schema: incompatible == 'schema'
              ? kCloudRowSchema + 1
              : kCloudRowSchema,
        );
        if (incompatible == 'column') {
          incoming['payload']['row']['future_column'] = 'not understood';
        }
        remote.incoming.add(incoming);
        await expectLater(
          engine.synchronize(),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect((await version())['version'], 1);
        expect((await version())['conflict_id'], 'old-conflict');
        expect(
          await device.local.rows('SELECT * FROM cloud_dirty'),
          hasLength(1),
        );
        expect(
          await device.local.rows('SELECT * FROM cloud_inbox'),
          hasLength(1),
        );
        expect(remote.sent, isEmpty);
      },
    );
  }

  test('sending messages do not take the matching shortcut', () async {
    await device.local.execute(
      "UPDATE messages SET status='sending' WHERE id='message'",
    );
    await remember(await document(version: 1));
    remote.incoming.add(await document(version: 2));
    await engine.synchronize();
    expect((await version())['version'], 1);
    expect((await version())['conflict_id'], 'old-conflict');
    expect(await device.local.rows('SELECT * FROM cloud_dirty'), hasLength(1));
    expect(remote.sent, isEmpty);
  });

  test(
    'frozen outbox stays immutable and blocks matching convergence',
    () async {
      await remember(await document(version: 1));
      await device.local.mark('messages', 'message');
      final mutation = {
        'op_id': 'frozen',
        'kind': 'messages',
        'entity_id': 'message',
        'base_version': 1,
        'action': 'put',
        'payload_version': 1,
        'payload': (await document())['payload'],
        'blob_ids': [],
        'media_ids': [],
      };
      remote.beforePull = () async {
        await device.local.execute(
          'INSERT INTO cloud_outbox VALUES(?,?,?,?,?,?)',
          [
            'frozen',
            'messages',
            'message',
            1,
            jsonEncode(mutation),
            'frozen baseline',
          ],
        );
        remote.failPush = true;
      };
      remote.incoming.add(await document(version: 3));
      await expectLater(engine.synchronize(), throwsA(isA<SocketException>()));
      final frozen = (await device.local.rows(
        'SELECT * FROM cloud_outbox',
      )).single;
      expect(frozen['mutation_json'], jsonEncode(mutation));
      expect(frozen['local_json'], 'frozen baseline');
      expect((await version())['version'], 1);
      expect((await version())['conflict_id'], 'old-conflict');
      expect(
        await device.local.rows('SELECT * FROM cloud_dirty'),
        hasLength(1),
      );
      expect(
        await device.local.rows('SELECT * FROM cloud_inbox'),
        hasLength(1),
      );
      expect(remote.sent, isEmpty);
    },
  );
}
