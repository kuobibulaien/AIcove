import 'dart:io';
import 'dart:convert';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('complete message snapshot lookup does not scan every block', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final child in {
      'message_blocks': 'message_id',
      'message_projection_mappings': 'raw_message_id',
    }.entries) {
      final plans = await db
          .customSelect(
            "EXPLAIN QUERY PLAN SELECT * FROM ${child.key} WHERE ${child.value}='probe' ORDER BY id",
          )
          .get();
      final details = plans.map((row) => row.read<String>('detail')).join(' ');
      expect(details, contains('SEARCH'), reason: details);
      expect(details, isNot(contains('SCAN')), reason: details);
      expect(details, isNot(contains('TEMP B-TREE')), reason: details);
    }
  });
  test(
    'legacy comparison migration resumes across batches and keeps dirty edits',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final root = await Directory.systemTemp.createTemp('sync-baseline-');
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final store = CloudLocalStore(
        db,
        await SharedPreferences.getInstance(),
        root,
        root,
      );
      await store.execute(
        "UPDATE cloud_client_state SET mode='receive',enabled=1 WHERE id=1",
      );
      await db.transaction(() async {
        for (var i = 0; i < 251; i++) {
          final raw = canonicalJson({
            'kind': 'diaries',
            'payload': {'entry': i},
          });
          await store
              .execute('INSERT INTO cloud_versions VALUES(?,?,?,?,?,?)', [
                'diaries',
                'entry-$i',
                1,
                i < 2 ? 'sha256:${cloudObjectId(raw)}' : raw,
                '{}',
                null,
              ]);
        }
        await store.mark('diaries', 'entry-7');
      });
      await store.prepareMessageSnapshots();
      expect(
        (await store.rows(
          "SELECT count(*) AS n FROM cloud_versions WHERE length(local_json)=71 AND local_json LIKE 'sha256:%'",
        )).single['n'],
        251,
      );
      expect(
        (await store.rows('SELECT count(*) AS n FROM cloud_dirty')).single['n'],
        1,
      );
      final before = await store.rows('SELECT * FROM cloud_dirty');
      await store.prepareMessageSnapshots();
      expect(await store.rows('SELECT * FROM cloud_dirty'), before);
    },
  );
  test(
    'receiver media normalization preserves clean baseline and real edits',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final root = await Directory.systemTemp.createTemp('sync-normalize-');
      final media = MediaStore(Directory('${root.path}/media'), 'receiver');
      addTearDown(() async {
        await media.close();
        await db.close();
        await root.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues({});
      final local = CloudLocalStore(
        db,
        await SharedPreferences.getInstance(),
        root,
        root,
      );
      await local.execute(
        "UPDATE cloud_client_state SET mode='receive',enabled=1 WHERE id=1",
      );
      await local.execute(
        "INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES('c','fixture','fixture',1,1)",
      );
      for (final id in ['clean', 'edited']) {
        final raw = jsonEncode({
          'toolAudioResults': [
            {
              'audioUrl': UriData.fromBytes(
                List.filled(40, 7),
                mimeType: 'audio/wav',
              ).toString(),
            },
          ],
        });
        await local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
          [id, 'c', 'assistant', 'fixture', 1, raw],
        );
        final doc = (await local.read('messages', id))!;
        await local.execute('INSERT INTO cloud_versions VALUES(?,?,?,?,?,?)', [
          'messages',
          id,
          1,
          doc.localJson,
          '{}',
          null,
        ]);
      }
      await local.execute('DELETE FROM cloud_dirty');
      await local.execute(
        "UPDATE messages SET content='local edit' WHERE id='edited'",
      );
      await local.compactEmbeddedMedia(mediaStore: media);
      await local.mark('messages', 'clean');
      await local.pruneUnchangedReceiverEdits();
      final clean = (await local.read('messages', 'clean'))!;
      expect(
        clean.payload['row']['raw_payload'],
        isNot(contains('data:audio/')),
      );
      expect(
        (await local.rows(
          "SELECT local_json FROM cloud_versions WHERE entity_id='clean'",
        )).single['local_json'],
        clean.localJson,
      );
      expect(
        await local.rows(
          "SELECT entity_id FROM cloud_dirty WHERE kind='messages'",
        ),
        [
          {'entity_id': 'edited'},
        ],
      );
    },
  );
}
