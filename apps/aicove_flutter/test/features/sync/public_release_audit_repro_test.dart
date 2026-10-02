import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/media/media_asset.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_media.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'lan_repository_test.dart'
    show LanTestDevice, lanTestDevice, seedLan, copyLan;

void main() {
  late Directory root;
  late LanTestDevice a, b;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('public-release-audit-');
    a = await lanTestDevice(root, 'a');
    b = await lanTestDevice(root, 'b');
  });
  tearDown(() async {
    for (final d in [a, b]) {
      await d.media.close();
      await d.local.db.close();
    }
    await root.delete(recursive: true);
  });

  test(
    'first merge must preserve an uncaptured local message beyond the 500-row batch',
    () async {
      await seedLan(a);
      await seedLan(b);
      await b.local.db.transaction(() async {
        for (var i = 0; i < 1100; i++) {
          await b.local.execute(
            'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
            [
              'a${i.toString().padLeft(5, '0')}',
              'role',
              'user',
              'local history',
              1,
            ],
          );
        }
        await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
          'unsynchronized local edit',
          'message',
        ]);
      });
      await a.repo.capture();
      final page = await a.repo.manifest();
      final item = (page['items'] as List).firstWhere(
        (x) => x['kind'] == 'messages',
      );
      final revision = await a.repo.revision(
        (item['hashes'] as List).single as String,
      );
      await b.repo.capture();
      await b.repo.receive(revision);
      final row = (await b.local.read('messages', 'message'))!.payload['row'];
      print(
        'AUDIT first-merge content=${row['content']}, conflicts=${(await b.repo.conflicts()).length}',
      );
      expect(row['content'], 'unsynchronized local edit');
    },
  );

  test(
    'soft deletion versus offline role edit must retain an explicit conflict',
    () async {
      await seedLan(a);
      await copyLan(a, b);
      await copyLan(b, a);
      await a.local.execute(
        'UPDATE conversations SET deleted_at=?,purge_at=? WHERE id=?',
        [100, 200, 'role'],
      );
      await b.local.execute(
        'UPDATE conversations SET persona_prompt=? WHERE id=?',
        ['offline edit to keep', 'role'],
      );
      await copyLan(a, b);
      final row = (await b.local.read('conversations', 'role'))!.payload['row'];
      final conflicts = await b.repo.conflicts();
      print(
        'AUDIT soft-delete deleted_at=${row['deleted_at']}, persona_prompt=${row['persona_prompt']}, conflicts=${conflicts.length}',
      );
      expect(conflicts, isNotEmpty);
      expect(row['deleted_at'], isNull);
    },
  );

  test(
    'eight unavailable attachments must not permanently starve later attachments',
    () async {
      final requests = <String>[];
      final peer = LanPeer(
        id: 'a',
        name: 'source',
        key: '',
        endpoints: [],
        approved: true,
      )..online = true;
      final media = LanMedia(b.local, b.media, (peer, body) async {
        final id = body['id'] as String;
        requests.add(id);
        return {
          'asset': MediaAsset(
            id: id,
            mimeType: 'image/png',
            byteLength: 0,
            createdAtMs: 1,
          ).toJson(),
        };
      });
      for (var i = 0; i < 9; i++) {
        final id = i.toRadixString(16).padLeft(64, '0');
        await b.local.execute(
          'INSERT INTO lan_media_queue(media_id,peer_id,asset_json) VALUES(?,?,?)',
          [
            id,
            'a',
            jsonEncode(
              MediaAsset(
                id: id,
                mimeType: 'image/png',
                byteLength: 0,
                createdAtMs: 1,
              ).toJson(),
            ),
          ],
        );
      }
      for (var i = 0; i < 3; i++) {
        await media.drain({'a': peer}, () => true);
      }
      print(
        'AUDIT attachments attempted=${requests.toSet().length}, total requests=${requests.length}',
      );
      expect(requests.toSet(), hasLength(9));
    },
  );
}
