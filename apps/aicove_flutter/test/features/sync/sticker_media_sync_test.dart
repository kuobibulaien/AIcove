import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';

import 'lan_repository_test.dart' show LanTestDevice, lanTestDevice, seedLan;

void main() {
  late Directory root;
  late LanTestDevice source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sticker-sync-');
    source = await lanTestDevice(root, 'source');
  });
  tearDown(() async {
    await source.media.close();
    await source.local.db.close();
    await root.delete(recursive: true);
  });

  Future<File> picture(String name) async =>
      File('${root.path}/$name.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));

  Map<String, dynamic> event(String path, {bool byPlugin = false}) => {
    if (byPlugin) 'pluginId': 'sticker',
    'type': byPlugin ? 'legacy_convert' : 'sticker_convert',
    'data': {'assetPath': path, 'stickerId': 'local-uuid', 'tag': '抱抱'},
  };

  test(
    'sticker events and emoji references pin originals without pinning photos',
    () async {
      final sticker = await picture('sticker');
      final photo = await picture('photo');
      photo.writeAsBytesSync(img.encodePng(img.Image(width: 3, height: 3)));
      final raw = {
        'pluginEvents': [event(sticker.path)],
        'replyRounds': [
          {
            'pluginEvents': [event(sticker.path, byPlugin: true)],
          },
        ],
        'projectedMessages': [
          {
            'blocks': [
              {'type': 'emoji', 'path': sticker.path},
            ],
          },
        ],
        'arguments': event(sticker.path),
      };
      final wire = await source.repo.codec.encode(
        CloudLocalDocument('messages', 'm', {
          'row': {
            'id': 'm',
            'role': 'assistant',
            'created_at': 1,
            'raw_payload': jsonEncode(raw),
          },
          'message_blocks': [
            {
              'type': 'emoji',
              'data': jsonEncode({'type': 'emoji', 'path': sticker.path}),
            },
            {
              'type': 'image',
              'data': jsonEncode({'type': 'image', 'localPath': photo.path}),
            },
          ],
        }),
      );
      final encoded =
          jsonDecode((wire.payload['row'] as Map)['raw_payload'] as String)
              as Map;
      final reference =
          encoded['pluginEvents'][0]['data']['assetPath'] as String;
      final id = mediaIdFromReference(reference);
      expect(id, isNotNull);
      expect(
        encoded['replyRounds'][0]['pluginEvents'][0]['data']['assetPath'],
        reference,
      );
      expect(encoded['projectedMessages'][0]['blocks'][0]['path'], reference);
      expect(encoded['arguments'], raw['arguments']);
      expect(wire.mediaIds, hasLength(2));
      expect((await source.media.load(id!))!.asset.originalRequired, isTrue);
      final photoId = wire.mediaIds.singleWhere((value) => value != id);
      expect(
        (await source.media.load(photoId))!.asset.originalRequired,
        isFalse,
      );
      CloudMediaCodec.validateWirePaths(wire.payload);
      final decoded = await source.repo.codec.decode('messages', wire.payload);
      expect(
        jsonDecode(
          (decoded['row'] as Map)['raw_payload'] as String,
        )['pluginEvents'][0]['data']['assetPath'],
        reference,
      );
    },
  );

  test('already managed sticker promotes usage to originalRequired', () async {
    final record = await source.media.register(
      (await picture('existing')).path,
      createdAtMs: 1,
    );
    expect(record.asset.originalRequired, isFalse);
    await source.repo.codec.encode(
      CloudLocalDocument('messages', 'm', {
        'pluginEvents': [event(record.asset.reference)],
      }),
    );
    expect(
      (await source.media.load(record.asset.id))!.asset.originalRequired,
      isTrue,
    );
  });

  test(
    'wire validation rejects scoped sticker paths but not unrelated assetPath',
    () {
      expect(
        () => CloudMediaCodec.validateWirePaths({
          'pluginEvents': [event('/path/to/home/stickers/files/a.png')],
        }),
        throwsFormatException,
      );
      expect(
        () => CloudMediaCodec.validateWirePaths({
          'replyRounds': [
            {
              'pluginEvents': [
                event(r'C:\stickers\files\a.png', byPlugin: true),
              ],
            },
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => CloudMediaCodec.validateWirePaths({
          'assetPath': '/path/to/home/value',
        }),
        returnsNormally,
      );
    },
  );

  test(
    'source repair creates a new causal revision and leaves frozen operations intact',
    () async {
      await seedLan(source);
      final path = (await picture('legacy')).path;
      final raw = jsonEncode({
        'pluginEvents': [event(path)],
        'replyRounds': [
          {
            'pluginEvents': [event(path)],
          },
        ],
        'projectedMessages': [
          {
            'blocks': [
              {'type': 'emoji', 'path': path},
            ],
          },
        ],
      });
      await source.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [raw, 'message'],
      );
      await source.local.execute(
        'INSERT INTO message_blocks(id,message_id,type,data,created_at,sort_order) VALUES(?,?,?,?,?,?)',
        [
          'emoji',
          'message',
          'emoji',
          jsonEncode({'type': 'emoji', 'path': path}),
          1,
          0,
        ],
      );
      final current = (await source.local.read('messages', 'message'))!;
      final old = LanRevision(
        kind: 'messages',
        id: 'message',
        vector: {'source': 1},
        payload: current.payload,
      );
      final frozen = canonicalJson(old.toJson());
      await source.local.execute('INSERT INTO lan_revisions VALUES(?,?,?,?)', [
        old.hash,
        old.kind,
        old.id,
        frozen,
      ]);
      final fingerprint = cloudObjectId(
        canonicalJson({
          'payload': Map.of(current.payload)..remove('client_schema'),
        }),
      );
      await source.local.execute('INSERT INTO lan_entities VALUES(?,?,?,?)', [
        'messages',
        'message',
        jsonEncode([old.hash]),
        fingerprint,
      ]);
      await source.local.execute(
        'INSERT INTO cloud_outbox VALUES(?,?,?,?,?,?)',
        ['frozen-op', 'messages', 'message', 1, frozen, current.localJson],
      );
      await source.local.execute('DELETE FROM lan_dirty');
      await source.local.execute('DELETE FROM cloud_dirty');

      expect(
        await source.local.repairLegacyStickerMedia(mediaStore: source.media),
        2,
      );
      final repaired = (await source.local.read('messages', 'message'))!;
      final repairedRaw = jsonDecode(
        (repaired.payload['row'] as Map)['raw_payload'] as String,
      );
      final reference =
          repairedRaw['pluginEvents'][0]['data']['assetPath'] as String;
      expect(mediaIdFromReference(reference), isNotNull);
      expect(
        repairedRaw['replyRounds'][0]['pluginEvents'][0]['data']['assetPath'],
        reference,
      );
      expect(
        repairedRaw['projectedMessages'][0]['blocks'][0]['path'],
        reference,
      );
      expect(
        await source.local.rows(
          "SELECT 1 FROM lan_dirty WHERE entity_id='message'",
        ),
        hasLength(1),
      );
      expect(
        await source.local.rows(
          "SELECT 1 FROM cloud_dirty WHERE entity_id='message'",
        ),
        hasLength(1),
      );
      expect(
        (await source.local.rows(
          'SELECT document_json FROM lan_revisions WHERE hash=?',
          [old.hash],
        )).single['document_json'],
        frozen,
      );
      expect(
        (await source.local.rows(
          "SELECT mutation_json FROM cloud_outbox WHERE op_id='frozen-op'",
        )).single['mutation_json'],
        frozen,
      );

      await source.repo.capture(scanExternal: false);
      final head =
          jsonDecode(
                (await source.local.rows(
                      "SELECT heads_json FROM lan_entities WHERE entity_id='message'",
                    )).single['heads_json']
                    as String,
              )
              as List;
      final revision = await source.repo.revision(head.single as String);
      expect(revision.mediaIds, [mediaIdFromReference(reference)]);
      expect(revision.vector['source'], 2);
      final revisionCount = (await source.local.rows(
        'SELECT hash FROM lan_revisions',
      )).length;
      expect(
        await source.local.repairLegacyStickerMedia(mediaStore: source.media),
        0,
      );
      await source.repo.capture(scanExternal: false);
      expect(
        (await source.local.rows('SELECT hash FROM lan_revisions')).length,
        revisionCount,
      );
    },
  );

  test(
    'LAN initialization repairs once but missing receiver paths remain byte-for-byte unchanged',
    () async {
      await seedLan(source);
      final missing = jsonEncode({
        'pluginEvents': [
          event('/not-on-this-device/stickers/files/missing.png'),
        ],
      });
      await source.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [missing, 'message'],
      );
      await source.local.execute('DELETE FROM lan_dirty');
      await source.local.execute('DELETE FROM cloud_dirty');
      expect(
        await source.local.repairLegacyStickerMedia(mediaStore: source.media),
        0,
      );
      expect(
        (await source.local.rows(
          "SELECT raw_payload FROM messages WHERE id='message'",
        )).single['raw_payload'],
        missing,
      );
      expect(await source.local.rows('SELECT * FROM lan_dirty'), isEmpty);
      expect(await source.local.rows('SELECT * FROM cloud_dirty'), isEmpty);

      // A fresh store starts the migration through capture, without cloud sync.
      await source.local.execute(
        "DELETE FROM cloud_local_migrations WHERE name='sticker_message_media_v1'",
      );
      final raw = jsonEncode({
        'pluginEvents': [event((await picture('startup')).path)],
      });
      await source.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [raw, 'message'],
      );
      await source.repo.capture(scanExternal: false);
      final repaired =
          (await source.local.rows(
                "SELECT raw_payload FROM messages WHERE id='message'",
              )).single['raw_payload']
              as String;
      expect(
        mediaIdFromReference(
          jsonDecode(repaired)['pluginEvents'][0]['data']['assetPath']
              as String,
        ),
        isNotNull,
      );
    },
  );

  test(
    'deletion accepts stale sticker paths while live revisions reject them',
    () async {
      await seedLan(source);
      final payload = (await source.local.read('messages', 'message'))!.payload;
      final stale = {
        ...payload,
        'row': {
          ...payload['row'] as Map,
          'raw_payload': jsonEncode({
            'pluginEvents': [event('/path/to/home/missing.png')],
          }),
        },
      };
      await expectLater(
        source.repo.receive(
          LanRevision(
            kind: 'messages',
            id: 'message',
            vector: {'source': 100},
            payload: stale,
          ),
        ),
        throwsA(isA<LanSyncFailure>()),
      );
      await source.repo.receive(
        LanRevision(
          kind: 'messages',
          id: 'message',
          vector: {'source': 100},
          payload: stale,
          deleted: true,
        ),
      );
      expect(await source.local.read('messages', 'message'), isNull);
    },
  );

  test(
    'cloud compaction repairs existing local stickers and skips in-flight history',
    () async {
      await seedLan(source);
      final raw = jsonEncode({
        'pluginEvents': [event((await picture('cloud')).uri.toString())],
      });
      await source.local.execute(
        'UPDATE messages SET raw_payload=? WHERE id=?',
        [raw, 'message'],
      );
      await source.local.execute(
        "INSERT INTO messages(id,conversation_id,role,content,created_at,status,raw_payload) VALUES(?,?,?,?,?,?,?)",
        ['sending', 'role', 'assistant', '', 1, 'sending', raw],
      );
      await source.local.execute(
        'INSERT INTO message_blocks(id,message_id,type,data,created_at,sort_order) VALUES(?,?,?,?,?,?)',
        [
          'sending-emoji',
          'sending',
          'emoji',
          jsonEncode({'path': (await picture('in-flight')).path}),
          1,
          0,
        ],
      );
      await source.local.compactEmbeddedMedia(mediaStore: source.media);
      final repaired =
          (await source.local.rows(
                "SELECT raw_payload FROM messages WHERE id='message'",
              )).single['raw_payload']
              as String;
      expect(
        mediaIdFromReference(
          jsonDecode(repaired)['pluginEvents'][0]['data']['assetPath']
              as String,
        ),
        isNotNull,
      );
      expect(
        (await source.local.rows(
          "SELECT raw_payload FROM messages WHERE id='sending'",
        )).single['raw_payload'],
        raw,
      );
      final pending =
          (await source.local.rows(
                "SELECT data FROM message_blocks WHERE id='sending-emoji'",
              )).single['data']
              as String;
      expect(jsonDecode(pending)['path'], endsWith('in-flight.png'));
    },
  );
}
