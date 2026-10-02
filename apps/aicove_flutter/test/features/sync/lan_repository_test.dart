import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';

class LanMemoryPreferences implements SharedPreferences {
  final values = <String, Object>{};
  @override
  Set<String> getKeys() => values.keys.toSet();
  @override
  Object? get(String key) => values[key];
  @override
  String? getString(String key) => values[key] as String?;
  @override
  bool? getBool(String key) => values[key] as bool?;
  @override
  Future<void> reload() async {}
  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    values[key] = value;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LanTestDevice {
  LanTestDevice(this.local, this.media, this.repo);
  final CloudLocalStore local;
  final MediaStore media;
  final LanRepository repo;
}

Future<LanTestDevice> lanTestDevice(Directory root, String id) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  await db.customStatement('PRAGMA foreign_keys=ON');
  final local = CloudLocalStore(
    db,
    LanMemoryPreferences(),
    Directory('${root.path}/$id/docs')..createSync(recursive: true),
    Directory('${root.path}/$id/support')..createSync(recursive: true),
  );
  final media = MediaStore(Directory('${root.path}/$id/media'), id);
  return LanTestDevice(
    local,
    media,
    LanRepository(
      local,
      CloudMediaCodec(media, allowNetworkDownload: false),
      id,
    ),
  );
}

Future<void> seedLan(LanTestDevice d) async {
  await d.local.execute(
    'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
    ['role', '角色', '角色', 1, 1],
  );
  await d.local.execute(
    'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
    ['message', 'role', 'assistant', '原文', 1, '{"text":"原文"}'],
  );
}

Future<void> copyLan(LanTestDevice from, LanTestDevice to) async {
  await from.repo.capture();
  final manifest = await from.repo.manifest();
  for (final item in manifest['items'] as List) {
    for (final hash in await to.repo.missing(
      (item['hashes'] as List).cast<String>(),
    )) {
      await to.repo.receive(await from.repo.revision(hash));
    }
  }
}

void main() {
  late Directory root;
  late LanTestDevice a, b, c;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('aicove-lan-test-');
    a = await lanTestDevice(root, 'a');
    b = await lanTestDevice(root, 'b');
    c = await lanTestDevice(root, 'c');
  });
  tearDown(() async {
    for (final d in [a, b, c]) {
      await d.media.close();
      await d.local.db.close();
    }
    await root.delete(recursive: true);
  });
  test(
    'remote attachment paths are rejected without rewriting ordinary text',
    () async {
      await seedLan(a);
      await copyLan(a, b);
      final original = (await a.local.read('conversations', 'role'))!;
      final fixture = File('${root.path}/private-fixture.txt');
      await fixture.writeAsString('local fixture');
      for (final path in [
        fixture.path,
        r'C:\private\fixture.txt',
        fixture.uri.toString(),
      ]) {
        final revision = LanRevision(
          kind: 'conversations',
          id: 'role',
          vector: {'remote': 1},
          payload: {
            ...original.payload,
            'row': {
              ...original.payload['row'] as Map,
              'chat_background_image': path,
            },
          },
        );
        await expectLater(
          b.repo.receive(revision),
          throwsA(isA<LanSyncFailure>()),
        );
        expect(
          (await b.local.read(
            'conversations',
            'role',
          ))!.payload['row']['chat_background_image'],
          isNull,
        );
        expect(await fixture.readAsString(), 'local fixture');
        expect(
          await b.local.rows('SELECT 1 FROM lan_revisions WHERE hash=?', [
            revision.hash,
          ]),
          isEmpty,
        );
        expect(
          () => CloudMediaCodec.validateWirePaths({
            'row': {
              'raw_payload': jsonEncode({'image_path': path}),
            },
          }),
          throwsFormatException,
        );
      }
      final message = (await a.local.read('messages', 'message'))!;
      await b.repo.receive(
        LanRevision(
          kind: 'messages',
          id: 'ordinary-text',
          vector: {'remote': 2},
          payload: {
            ...message.payload,
            'row': {
              ...message.payload['row'] as Map,
              'id': 'ordinary-text',
              'content': fixture.path,
              'raw_payload': jsonEncode({'text': fixture.path}),
            },
          },
        ),
      );
      expect(
        (await b.local.read(
          'messages',
          'ordinary-text',
        ))!.payload['row']['content'],
        fixture.path,
      );
    },
  );
  test(
    'first merge keeps raw content and does not consume cloud journal',
    () async {
      await seedLan(a);
      final cloudBefore = await a.local.rows('SELECT * FROM cloud_dirty');
      await copyLan(a, b);
      await copyLan(b, a);
      expect(
        (await b.local.read(
          'messages',
          'message',
        ))!.payload['row']['raw_payload'],
        '{"text":"原文"}',
      );
      expect(await a.local.rows('SELECT * FROM cloud_dirty'), cloudBefore);
      expect(await a.repo.conflicts(), isEmpty);
      expect(await b.local.rows('SELECT * FROM lan_dirty'), isEmpty);
    },
  );
  test(
    'offline message edits retain both and explicit resolution reaches third device',
    () async {
      await seedLan(a);
      await copyLan(a, b);
      await copyLan(b, c);
      await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'a编辑',
        'message',
      ]);
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'b编辑',
        'message',
      ]);
      await copyLan(a, b);
      await copyLan(b, a);
      final conflict = (await a.repo.conflicts()).single;
      expect(conflict.length, 2);
      expect(
        (await a.local.read('messages', 'message'))!.payload['row']['content'],
        'a编辑',
      );
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'b编辑',
      );
      final chosen = conflict.firstWhere(
        (r) => r.payload['row']['content'] == 'b编辑',
      );
      await a.repo.resolve(
        'messages',
        'message',
        chosen.hash,
        conflict.map((r) => r.hash).toList(),
      );
      await copyLan(a, b);
      await copyLan(b, c);
      expect(await b.repo.conflicts(), isEmpty);
      expect(
        (await c.local.read('messages', 'message'))!.payload['row']['content'],
        'b编辑',
      );
      await expectLater(
        a.repo.resolve(
          'messages',
          'message',
          chosen.hash,
          conflict.map((r) => r.hash).toList(),
        ),
        throwsA(isA<LanSyncFailure>()),
      );
    },
  );
  test('later setting clear and General values remain device-local', () async {
    await saveCloudPreference(
      a.local.preferences,
      'aicove.ui_models.v1',
      jsonEncode({'is_dark_mode': true, 'active_model': 'old'}),
      atMs: 1000,
    );
    await saveCloudPreference(
      b.local.preferences,
      'aicove.ui_models.v1',
      jsonEncode({'is_dark_mode': false}),
      atMs: 1000,
    );
    await copyLan(a, b);
    await copyLan(b, a);
    await saveCloudPreference(
      a.local.preferences,
      'aicove.ui_models.v1',
      jsonEncode({'is_dark_mode': true, 'active_model': 'a'}),
      atMs: 5000,
    );
    await saveCloudPreference(
      b.local.preferences,
      'aicove.ui_models.v1',
      jsonEncode({'is_dark_mode': false, 'active_model': null}),
      atMs: 6000,
    );
    await copyLan(a, b);
    await copyLan(b, a);
    final av =
        jsonDecode(a.local.preferences.getString('aicove.ui_models.v1')!)
            as Map;
    final bv =
        jsonDecode(b.local.preferences.getString('aicove.ui_models.v1')!)
            as Map;
    expect(av['is_dark_mode'], true);
    expect(bv['is_dark_mode'], false);
    expect(av['active_model'], isNull);
    expect(bv['active_model'], isNull);
    expect(await a.repo.conflicts(), isEmpty);
  });
  test(
    'delete vs offline edit remains conflict, repeated delivery creates no extra edits',
    () async {
      await seedLan(a);
      await copyLan(a, b);
      await a.local.execute('DELETE FROM messages WHERE id=?', ['message']);
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        '离线编辑',
        'message',
      ]);
      await copyLan(a, b);
      await copyLan(b, a);
      expect((await a.repo.conflicts()).single.any((r) => r.deleted), true);
      expect(await a.local.read('messages', 'message'), isNull);
      final count = (await a.local.rows(
        'SELECT counter FROM lan_state',
      )).single['counter'];
      await copyLan(b, a);
      expect(
        (await a.local.rows('SELECT counter FROM lan_state')).single['counter'],
        count,
      );
    },
  );
}
