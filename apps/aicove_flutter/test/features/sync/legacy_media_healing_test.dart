import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_media.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';

import 'lan_repository_test.dart'
    show LanTestDevice, LanCountingLocalStore, lanTestDevice, seedLan;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LanTestDevice device;
  late LanPeer peer;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('legacy-media-healing-');
    device = await lanTestDevice(root, 'local');
    peer = LanPeer(
      id: 'source',
      name: 'source',
      key: 'test',
      endpoints: [],
      approved: true,
    )..online = true;
    await seedLan(device);
  });
  tearDown(() async {
    await device.media.close();
    await device.local.db.close();
    await root.delete(recursive: true);
  });

  String digest(String text) => sha256.convert(utf8.encode(text)).toString();
  MediaAsset asset(
    String name, {
    bool tombstone = false,
    bool downloadable = false,
  }) => MediaAsset(
    id: digest(name),
    mimeType: 'audio/wav',
    byteLength: tombstone ? 0 : 7,
    createdAtMs: 1,
    originalSha256: tombstone ? null : digest(name),
    originalBlob: downloadable ? digest(name) : null,
  );
  Future<void> queue(MediaAsset a, {String source = 'source'}) =>
      device.local.execute(
        'INSERT OR REPLACE INTO lan_media_queue VALUES(?,?,?)',
        [a.id, source, jsonEncode(a.toJson())],
      );
  Future<void> reference(
    String id,
    MediaAsset a, {
    bool deleted = false,
    String? replacedBy,
  }) => device.local.execute(
    'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload,deleted_at,replaced_by) VALUES(?,?,?,?,?,?,?,?)',
    [
      id,
      'role',
      'assistant',
      '',
      1,
      jsonEncode({'filePath': a.reference}),
      deleted ? 2 : null,
      replacedBy,
    ],
  );

  Future<Map<String, dynamic>> legacy() async {
    final good = await device.media.register(
      (File(
        '${root.path}/good.png',
      )..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)))).path,
      createdAtMs: 1,
    );
    final dead = await device.media.unavailable('/missing.png', createdAtMs: 1);
    final payload = {
      'version': 1,
      'projectedMessages': [
        {
          'id': 'message__proj_01_image',
          'role': 'user',
          'content': '',
          'createdAt': 1,
          'blocks': [
            {
              'id': 'derived',
              'messageId': 'message__proj_01_image',
              'type': 'image',
              'status': 'success',
              'localPath': dead.asset.reference,
            },
          ],
        },
      ],
    };
    await device.local.execute(
      'UPDATE messages SET role=?,raw_payload=? WHERE id=?',
      ['user', jsonEncode(payload), 'message'],
    );
    final block = {
      'id': 'original',
      'messageId': 'message',
      'type': 'image',
      'status': 'success',
      'localPath': good.asset.reference,
    };
    await device.local.execute(
      'INSERT INTO message_blocks(id,message_id,type,data,created_at) VALUES(?,?,?,?,?)',
      ['original', 'message', 'image', jsonEncode(block), 1],
    );
    return {'good': good.asset.id, 'dead': dead.asset.id};
  }

  test(
    'one-time migration preserves clean receive baseline and frozen outbox bytes',
    () async {
      final ids = await legacy();
      final before = (await device.local.read('messages', 'message'))!;
      await device.local.execute(
        "UPDATE cloud_client_state SET mode='receive' WHERE id=1",
      );
      await device.local.execute('DELETE FROM cloud_dirty');
      await device.local.execute(
        'INSERT INTO cloud_versions(kind,entity_id,version,local_json,cloud_json) VALUES(?,?,?,?,?)',
        ['messages', 'message', 1, before.localJson, '{"frozen":true}'],
      );
      await device.local.execute(
        'INSERT INTO cloud_outbox VALUES(?,?,?,?,?,?)',
        [
          'frozen',
          'messages',
          'message',
          1,
          '{"immutable":true}',
          before.localJson,
        ],
      );
      expect(await device.local.normalizeLegacyMessageMedia(), 1);
      final after = (await device.local.read('messages', 'message'))!;
      expect(jsonEncode(after.payload), contains(ids['good']));
      expect(
        (after.payload['row'] as Map)['raw_payload'],
        isNot(contains(ids['dead'])),
      );
      expect(
        (await device.local.rows(
          'SELECT local_json FROM cloud_versions',
        )).single['local_json'],
        after.localJson,
      );
      expect(
        await device.local.rows(
          "SELECT * FROM cloud_dirty WHERE kind='messages'",
        ),
        isEmpty,
      );
      expect(
        (await device.local.rows(
          'SELECT mutation_json,local_json FROM cloud_outbox',
        )).single,
        {'mutation_json': '{"immutable":true}', 'local_json': before.localJson},
      );
      expect(await device.local.normalizeLegacyMessageMedia(), 0);
      expect(
        (await device.local.read('messages', 'message'))!.localJson,
        after.localJson,
      );
    },
  );

  test(
    'migration leaves dirty receiver edits and pending revisions intact',
    () async {
      await legacy();
      await device.local.execute(
        "UPDATE cloud_client_state SET mode='receive' WHERE id=1",
      );
      await device.local.execute(
        'INSERT INTO cloud_versions(kind,entity_id,version,local_json,cloud_json) VALUES(?,?,?,?,?)',
        ['messages', 'message', 1, 'previous-edit', '{}'],
      );
      expect(await device.local.normalizeLegacyMessageMedia(), 1);
      expect(
        (await device.local.rows(
          'SELECT local_json FROM cloud_versions',
        )).single['local_json'],
        'previous-edit',
      );
      expect(
        await device.local.rows(
          "SELECT * FROM cloud_dirty WHERE kind='messages'",
        ),
        isNotEmpty,
      );
    },
  );

  test('interrupted batches resume without duplicating completed media', () async {
    final payload = jsonEncode({
      'processedText': '正文',
      'projectedMessages': [
        {
          'id': 'old',
          'role': 'assistant',
          'content': '',
          'createdAt': 1,
          'blocks': [
            {
              'id': 'image',
              'messageId': 'old',
              'type': 'image',
              'status': 'success',
              'localPath': '/image.png',
            },
          ],
        },
      ],
    });
    for (var i = 0; i < 101; i++) {
      await device.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
        [
          'batch_${i.toString().padLeft(3, '0')}',
          'role',
          'assistant',
          '原文',
          1,
          payload,
        ],
      );
    }
    var updates = 0;
    (device.local as LanCountingLocalStore).beforeExecute = (sql, _) async {
      if (sql.startsWith('UPDATE messages SET raw_payload=') &&
          ++updates == 101)
        throw StateError('interrupted');
    };
    await expectLater(
      device.local.normalizeLegacyMessageMedia(),
      throwsStateError,
    );
    expect(
      await device.local.rows(
        "SELECT * FROM cloud_local_migrations WHERE name='legacy_message_media_v1'",
      ),
      isEmpty,
    );
    (device.local as LanCountingLocalStore).beforeExecute = null;
    expect(await device.local.normalizeLegacyMessageMedia(), 1);
    expect(await device.local.normalizeLegacyMessageMedia(), 0);
    expect(
      (await device.local.rows(
        "SELECT COUNT(*) AS n FROM messages WHERE json_array_length(raw_payload,'\$.supplementInsertOps')=1",
      )).single['n'],
      101,
    );
  });

  test(
    'wire encode and receive align old snapshots without syncing duplicate IDs',
    () async {
      final ids = await legacy();
      final raw = (await device.local.read('messages', 'message'))!;
      final codec = CloudMediaCodec(device.media, allowNetworkDownload: false);
      final wire = await codec.encode(raw);
      expect(wire.mediaIds, contains(ids['good']));
      expect(wire.mediaIds, isNot(contains(ids['dead'])));
      final decoded = await codec.decode('messages', raw.payload);
      expect(
        (decoded['row'] as Map)['raw_payload'],
        isNot(contains(ids['dead'])),
      );
      final unknown =
          jsonDecode(jsonEncode(raw.payload)) as Map<String, dynamic>;
      unknown['row']['raw_payload'] = (unknown['row']['raw_payload'] as String)
          .replaceAll(ids['dead'] as String, digest('never-registered'));
      expect(
        (await codec.decode('messages', unknown))['row']['raw_payload'],
        isNot(contains(digest('never-registered'))),
      );
      await device.local.apply('messages', 'message', raw.payload, false);
      expect(
        ((await device.local.read('messages', 'message'))!.payload['row']
            as Map)['raw_payload'],
        isNot(contains(ids['dead'])),
      );
    },
  );

  test('path tombstones retain metadata but never queue or poll', () async {
    final a = asset('unknown', tombstone: true);
    var calls = 0;
    final lan = LanMedia(device.local, device.media, (_, _) async {
      calls++;
      return {'asset': a.toJson()};
    });
    await queue(a);
    await lan.prepare(peer, [a.id]);
    expect(await lan.counts(), (0, 0));
    expect(await device.media.load(a.id), isNotNull);
    await queue(a);
    await lan.drain({peer.id: peer}, () => true);
    expect(calls, 1);
    expect(await lan.counts(), (0, 0));
  });

  test(
    'history-only metadata does not queue; active shared references survive cleanup',
    () async {
      final a = asset('shared');
      final lan = LanMedia(
        device.local,
        device.media,
        (_, _) async => {'asset': a.toJson()},
      );
      await reference('deleted', a, deleted: true);
      await lan.prepare(peer, [a.id], download: false);
      expect(await lan.counts(), (0, 0));
      expect(await device.media.load(a.id), isNotNull);
      await queue(a);
      await reference('active', a);
      expect(await lan.reconcileQueue(), 0);
      await device.local.execute(
        'UPDATE messages SET replaced_by=? WHERE id=?',
        ['other', 'active'],
      );
      expect(await lan.reconcileQueue(), 1);
      await queue(a);
      await device.local.execute(
        'UPDATE conversations SET chat_background_image=? WHERE id=?',
        [a.reference, 'role'],
      );
      expect(await lan.reconcileQueue(), 0);
    },
  );

  test(
    'known missing contents remain unavailable; invalid local paths are not completion',
    () async {
      final a = asset('missing');
      await device.media.save(
        LocalMedia(a, originalPath: '${root.path}/does-not-exist.wav'),
      );
      final lan = LanMedia(
        device.local,
        device.media,
        (_, _) async => {'asset': a.toJson()},
      );
      await lan.prepare(peer, [a.id]);
      await lan.drain({peer.id: peer}, () => true);
      expect(await lan.counts(), (0, 1));
      final wrong = File('${root.path}/wrong.wav')..writeAsStringSync('wrong');
      await device.media.save(LocalMedia(a, originalPath: wrong.path));
      await lan.drain({peer.id: peer}, () => true);
      expect(await lan.counts(), (0, 1));
      await device.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [
          jsonEncode({'audioUrl': wrong.path}),
          'message',
        ],
      );
      expect(await lan.reconcileQueue(), 0);
    },
  );

  test('valid local originals finish without contacting the peer', () async {
    final file = File('${root.path}/original.wav')
      ..writeAsStringSync('original');
    final record = await device.media.register(file.path, createdAtMs: 1);
    final lan = LanMedia(
      device.local,
      device.media,
      (_, _) async => throw StateError('must not poll'),
    );
    await queue(record.asset);
    await lan.drain({peer.id: peer}, () => true);
    expect(await lan.counts(), (0, 0));
  });

  test('old drain response cannot overwrite a new source queue row', () async {
    final a = asset('race');
    final lan = LanMedia(device.local, device.media, (_, _) async {
      await queue(a, source: 'new-source');
      return {'asset': a.toJson()};
    });
    await queue(a);
    await lan.drain({peer.id: peer}, () => true);
    final remaining = (await device.local.rows(
      'SELECT * FROM lan_media_queue',
    )).single;
    expect(remaining['peer_id'], 'new-source');
    expect(
      jsonDecode(remaining['asset_json'] as String)['unavailable'],
      isNull,
    );
  });

  test(
    'identity staging survives reconciliation before business commit',
    () async {
      final a = asset('staged');
      final lan = LanMedia(
        device.local,
        device.media,
        (_, _) async => {'asset': a.toJson()},
      );
      final staged = await lan.prepareIdentities(peer, [a.id]);
      expect(await lan.counts(), (0, 0));
      expect(await lan.reconcileQueue(), 0);
      await reference('committed', a);
      await lan.enqueuePrepared(peer, staged);
      expect(await lan.reconcileQueue(), 0);
      expect(await lan.counts(), (1, 0));
    },
  );

  test('delayed prepare cannot overwrite a different source', () async {
    final a = asset('prepare-race');
    final lan = LanMedia(device.local, device.media, (_, _) async {
      await queue(a, source: 'new-source');
      return {'asset': a.toJson()};
    });
    await lan.prepare(peer, [a.id]);
    expect(
      (await device.local.rows(
        'SELECT peer_id FROM lan_media_queue',
      )).single['peer_id'],
      'new-source',
    );
  });

  test(
    'superseded snapshots do not own files when semantic media already exists',
    () async {
      final stale = asset('obsolete-snapshot');
      final current = asset('semantic-image');
      await queue(stale);
      await device.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [
          jsonEncode({
            'processedText': '正文',
            'pluginContents': [
              {'type': 'image', 'localPath': current.reference},
            ],
            'projectedMessages': [
              {
                'id': 'old',
                'role': 'assistant',
                'content': '',
                'createdAt': 1,
                'blocks': [
                  {
                    'id': 'old-image',
                    'messageId': 'old',
                    'type': 'image',
                    'status': 'success',
                    'localPath': stale.reference,
                  },
                ],
              },
            ],
          }),
          'message',
        ],
      );
      final lan = LanMedia(
        device.local,
        device.media,
        (_, _) async => throw StateError('no network'),
      );
      expect(await lan.reconcileQueue(), 1);
      expect(await lan.counts(), (0, 0));
    },
  );
  test('malformed legacy payload does not orphan a valid independent block', () async {
    final a = asset('independent-block');
    await queue(a);
    await device.local.execute('UPDATE messages SET raw_payload=? WHERE id=?', ['{broken', 'message']);
    await device.local.execute('INSERT INTO message_blocks(id,message_id,type,data,created_at) VALUES(?,?,?,?,?)', [
      'independent', 'message', 'image', jsonEncode({'id': 'independent', 'messageId': 'message', 'type': 'image', 'localPath': a.reference}), 1,
    ]);
    final lan = LanMedia(device.local, device.media, (_, _) async => throw StateError('no network'));
    expect(await lan.reconcileQueue(), 0);
    expect(await lan.counts(), (1, 0));
  });
}
