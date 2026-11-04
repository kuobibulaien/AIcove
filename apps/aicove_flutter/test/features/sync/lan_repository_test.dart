import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
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

class LanCountingLocalStore extends CloudLocalStore {
  LanCountingLocalStore(
    super.db,
    super.preferences,
    super.documents,
    super.support,
  );

  final revisionQueries = <(String, List<Object?>)>[];
  Completer<void>? externalEntered, externalRelease;
  final readCounts = <String, int>{};
  int validations = 0;

  @override
  Future<void> validateRowPayload(
    String kind,
    String id,
    Map<String, dynamic> payload,
  ) async {
    validations++;
    await super.validateRowPayload(kind, id, payload);
  }

  final readFailures = <String, Object>{};
  Future<void> Function(String, List<Object?>)? beforeExecute;

  @override
  Future<CloudLocalDocument?> read(
    String kind,
    String id, {
    bool includeRelated = true,
  }) async {
    if (includeRelated) {
      final key = '$kind/$id';
      readCounts.update(key, (n) => n + 1, ifAbsent: () => 1);
      final failure = readFailures[key];
      if (failure != null) throw failure;
    }
    return super.read(kind, id, includeRelated: includeRelated);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    await beforeExecute?.call(sql, args);
    await super.execute(sql, args);
  }

  @override
  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) {
    if (RegExp(r'FROM\s+lan_revisions\b', caseSensitive: false).hasMatch(sql)) {
      revisionQueries.add((sql, List.of(args)));
    }
    return super.rows(sql, args);
  }

  @override
  Future<List<CloudLocalDocument>> external() async {
    externalEntered?.complete();
    await externalRelease?.future;
    return super.external();
  }
}

Future<LanTestDevice> lanTestDevice(Directory root, String id) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  await db.customStatement('PRAGMA foreign_keys=ON');
  final local = LanCountingLocalStore(
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

LanRevision conflictRevision(String id, String device) => LanRevision(
  kind: 'messages',
  id: id,
  vector: {device: 1},
  payload: {
    'client_schema': 1,
    'row': {
      'id': id,
      'conversation_id': 'role',
      'role': 'assistant',
      'content': device,
      'created_at': 1,
      'status': 'sent',
    },
  },
);

Future<void> storeConflict(
  LanTestDevice device,
  List<LanRevision> heads,
) async {
  for (final head in heads) {
    await device.local.execute(
      'INSERT OR IGNORE INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
      [head.hash, head.kind, head.id, canonicalJson(head.toJson())],
    );
  }
  await device.local.execute(
    'INSERT OR REPLACE INTO lan_entities(kind,entity_id,heads_json,local_fingerprint) VALUES(?,?,?,?)',
    [
      heads.first.kind,
      heads.first.id,
      jsonEncode(heads.map((r) => r.hash).toList()),
      'x',
    ],
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
  for (final failure in [
    const LanSyncFailure('invalid record'),
    const CloudSyncFailure('unsupported record'),
    const FormatException('invalid JSON'),
  ]) {
    test('capture skips ${failure.runtimeType} and dequeues only its revision', () async {
      await seedLan(a);
      await a.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
        ['z-good', 'role', 'assistant', 'still captured', 2],
      );
      final local = a.local as LanCountingLocalStore;
      local.readFailures['messages/message'] = failure;
      final dirty =
          (await local.rows(
                "SELECT revision FROM lan_dirty WHERE kind='messages' AND entity_id='message'",
              )).single['revision']
              as int;
      var bumped = false;
      local.beforeExecute = (sql, args) async {
        if (!bumped &&
            sql.startsWith('DELETE FROM lan_dirty') &&
            args[1] == 'message') {
          bumped = true;
          await local.execute(
            "UPDATE lan_dirty SET revision=revision+1 WHERE kind='messages' AND entity_id='message'",
          );
        }
      };
      await a.repo.capture(scanExternal: false);
      expect(bumped, true);
      final warning = AppLogger.entries.value.lastWhere(
        (entry) => entry.message == '跳过无法打包的同步记录',
      );
      expect(warning.metadata, {
        'kind': 'messages',
        'entity_id': 'message',
        'revision': dirty,
        'errorType': failure.runtimeType.toString(),
      });
      expect(
        (await local.rows(
          "SELECT revision FROM lan_dirty WHERE kind='messages' AND entity_id='message'",
        )).single['revision'],
        dirty + 1,
      );
      expect(
        await local.rows(
          "SELECT * FROM lan_entities WHERE kind='messages' AND entity_id='z-good'",
        ),
        hasLength(1),
      );
      local.beforeExecute = null;
      await a.repo.capture(scanExternal: false);
      expect(
        await local.rows("SELECT * FROM lan_dirty WHERE kind='messages'"),
        isEmpty,
      );
      expect(
        (await local.read(
          'messages',
          'message',
          includeRelated: false,
        ))!.payload['row']['content'],
        '原文',
      );
    });
  }
  test(
    'capture propagates database failures instead of acknowledging dirty rows',
    () async {
      await seedLan(a);
      final local = a.local as LanCountingLocalStore;
      local.beforeExecute = (sql, args) async {
        if (sql.startsWith('INSERT OR IGNORE INTO lan_revisions') &&
            args[1] == 'messages') {
          await local.db.customStatement(
            'SELECT * FROM missing_infrastructure_table',
          );
        }
      };
      await expectLater(
        a.repo.capture(scanExternal: false),
        throwsA(isA<Exception>()),
      );
      local.beforeExecute = null;
      expect(
        await local.rows("SELECT * FROM lan_dirty WHERE kind='messages'"),
        hasLength(1),
      );
      expect(
        await local.rows("SELECT * FROM lan_entities WHERE kind='messages'"),
        isEmpty,
      );
    },
  );
  test('capture trims only oversized tool output on its wire copy', () async {
    await seedLan(a);
    final output = '开始${List.filled(3000000, '中').join()}结尾';
    final raw = jsonEncode({
      'text': 'preserved',
      'rawToolResults': [
        {
          'name': 'shell',
          'result': 'summary',
          'full_output_path': '/tmp/full.log',
          'structured': {'output': output, 'exit_code': 0},
          'extra': true,
        },
        {
          'result': 'small',
          'structured': {'output': 'unchanged'},
        },
      ],
    });
    expect(utf8.encode(raw).length, greaterThan(lanMaxDocumentBytes));
    await a.local.execute(
      "UPDATE messages SET raw_payload=? WHERE id='message'",
      [raw],
    );
    await a.repo.capture(scanExternal: false);
    final entity = (await a.local.rows(
      "SELECT * FROM lan_entities WHERE kind='messages'",
    )).single;
    final head = await a.repo.revision(
      (jsonDecode(entity['heads_json'] as String) as List).single as String,
    );
    expect(
      utf8.encode(canonicalJson(head.toJson())).length,
      lessThanOrEqualTo(lanMaxDocumentBytes),
    );
    final wire =
        jsonDecode((head.payload['row'] as Map)['raw_payload'] as String)
            as Map;
    final tools = wire['rawToolResults'] as List;
    final tail = tools.first['structured']['output'] as String;
    expect(utf8.encode(tail).length, lessThanOrEqualTo(32 * 1024));
    expect(tail, endsWith('结尾'));
    expect(tail, isNot(contains('�')));
    expect(tools.first, {
      ...(jsonDecode(raw)['rawToolResults'] as List).first as Map,
      'structured': {'output': tail, 'exit_code': 0},
    });
    expect(tools.last, (jsonDecode(raw)['rawToolResults'] as List).last);
    expect(wire['text'], 'preserved');
    expect(
      (await a.local.read(
        'messages',
        'message',
      ))!.payload['row']['raw_payload'],
      raw,
    );
    final before = await a.local.rows('SELECT counter FROM lan_state');
    await a.local.execute(
      "INSERT INTO lan_dirty(kind,entity_id) VALUES('messages','message')",
    );
    await a.repo.capture(scanExternal: false);
    expect(await a.local.rows('SELECT counter FROM lan_state'), before);
    expect(
      (await a.local.rows(
        "SELECT * FROM lan_entities WHERE kind='messages'",
      )).single,
      entity,
    );
    // A same-content peer head must converge without replacing full local
    // history with the shortened outgoing representation.
    final peer = LanRevision(
      kind: head.kind,
      id: head.id,
      vector: {'peer': 1},
      payload: head.payload,
      mediaIds: head.mediaIds,
    );
    await a.local.execute(
      'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
      [peer.hash, peer.kind, peer.id, canonicalJson(peer.toJson())],
    );
    await a.local.execute(
      "UPDATE lan_entities SET heads_json=? WHERE kind='messages'",
      [
        jsonEncode([head.hash, peer.hash]),
      ],
    );
    await a.local.execute(
      "INSERT INTO lan_dirty(kind,entity_id) VALUES('messages','message')",
    );
    await a.repo.capture(scanExternal: false);
    expect(
      (await a.local.read(
        'messages',
        'message',
      ))!.payload['row']['raw_payload'],
      raw,
    );
    expect(await a.local.rows('SELECT counter FROM lan_state'), before);
    await a.repo.receive(
      LanRevision(
        kind: head.kind,
        id: head.id,
        vector: {'another-peer': 1},
        payload: head.payload,
        mediaIds: head.mediaIds,
      ),
    );
    expect(
      (await a.local.read(
        'messages',
        'message',
      ))!.payload['row']['raw_payload'],
      raw,
    );
    expect(await a.local.rows('SELECT counter FROM lan_state'), before);
  });
  test(
    'untrimmable oversized record rolls back and does not block later rows',
    () async {
      await seedLan(a);
      await a.local.execute(
        "UPDATE messages SET content=? WHERE id='message'",
        [List.filled(lanMaxDocumentBytes + 1, 'x').join()],
      );
      await a.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
        ['z-good', 'role', 'assistant', 'good', 2],
      );
      await a.repo.capture(scanExternal: false);
      expect(
        await a.local.rows("SELECT * FROM lan_dirty WHERE kind='messages'"),
        isEmpty,
      );
      expect(
        (await a.local.rows(
          "SELECT entity_id FROM lan_entities WHERE kind='messages'",
        )).single['entity_id'],
        'z-good',
      );
      expect(
        (await a.local.rows('SELECT counter FROM lan_state')).single['counter'],
        2,
      );
      expect(
        (await a.local.read('messages', 'message'))!.payload['row']['content'],
        hasLength(lanMaxDocumentBytes + 1),
      );
    },
  );
  test(
    'orphan pruning invalidates missing cache hits after deleting revisions',
    () async {
      final head = conflictRevision('orphan', 'a');
      await storeConflict(a, [head]);
      await a.repo.revision(head.hash);
      await a.local.execute('DELETE FROM lan_entities');
      await a.repo.capture(scanExternal: false);
      expect(await a.local.rows('SELECT hash FROM lan_revisions'), isEmpty);
      expect(await a.repo.missing([head.hash]), [head.hash]);
    },
  );
  test('cold baseline captures only untracked rows after migration', () async {
    await seedLan(a);
    await a.repo.capture(scanExternal: false);
    await a.local.execute(
      'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
      ['untracked', 'role', 'assistant', 'baseline', 2],
    );
    await a.local.execute('DELETE FROM lan_dirty');
    final local = a.local as LanCountingLocalStore;
    local.readCounts.clear();
    final fresh = LanRepository(
      local,
      CloudMediaCodec(a.media, allowNetworkDownload: false),
      'a',
    );
    await fresh.capture(scanExternal: false);
    expect(local.readCounts['messages/message'], isNull);
    expect(local.readCounts['conversations/role'], isNull);
    expect(local.readCounts['messages/untracked'], 1);
    expect(
      await local.rows(
        "SELECT * FROM lan_entities WHERE entity_id='untracked'",
      ),
      hasLength(1),
    );
  });
  test('constructed revisions validate without a JSON round trip', () {
    final valid = conflictRevision('valid', 'device');
    expect(valid.validate, returnsNormally);
    expect(LanRevision.fromJson(valid.toJson()).hash, valid.hash);
    final invalid = LanRevision(
      kind: 'messages',
      id: 'invalid',
      vector: {},
      payload: {},
    );
    expect(invalid.validate, throwsA(isA<LanSyncFailure>()));
    final invalidTimes = LanRevision(
      kind: 'settings',
      id: 'invalid',
      vector: {'a': 1},
      payload: {},
    );
    expect(invalidTimes.validate, throwsA(isA<LanSyncFailure>()));
    expect(
      () => valid.validate(knownDocumentBytes: lanMaxDocumentBytes + 1),
      throwsA(isA<LanSyncFailure>()),
    );
  });

  test(
    'manifest summaries preserve hot revisions and detect changed documents',
    () async {
      final hot = conflictRevision('hot', 'a');
      await storeConflict(a, [hot]);
      final cached = await a.repo.revision(hot.hash);
      await a.local.db.transaction(() async {
        for (var i = 0; i < 2100; i++) {
          await storeConflict(a, [
            conflictRevision('scan-${i.toString().padLeft(4, '0')}', 'a'),
          ]);
        }
      });
      final local = a.local as LanCountingLocalStore;
      var after = '';
      do {
        final page = await a.repo.manifest(after: after, limit: 200);
        after = page['after'] as String;
        if (page['has_more'] != true) break;
      } while (true);
      expect(identical(await a.repo.revision(hot.hash), cached), isTrue);
      final validations = local.validations;
      after = '';
      do {
        final page = await a.repo.manifest(after: after, limit: 200);
        after = page['after'] as String;
        if (page['has_more'] != true) break;
      } while (true);
      expect(local.validations, validations);
      await a.local.execute(
        'UPDATE lan_revisions SET document_json=? WHERE hash=?',
        ['{}', hot.hash],
      );
      final page = await a.repo.manifest(limit: 200);
      expect(
        (page['items'] as List).where((item) => item['entity_id'] == 'hot'),
        isEmpty,
      );
    },
  );

  test(
    'recent relays received revisions and reuses unchanged assembled items',
    () async {
      await seedLan(b);
      await b.repo.capture();
      final manifest = await b.repo.manifest();
      for (final item in manifest['items'] as List) {
        for (final hash in item['hashes'] as List) {
          await a.repo.receive(await b.repo.revision(hash as String));
        }
      }
      final first = await a.repo.recentChanges();
      final second = await a.repo.recentChanges();
      expect(identical(first['items'], second['items']), isTrue);
      expect(first['revision'], greaterThan(0));
      expect(first['run'], isA<String>());
      expect(first['has_more_dirty'], false);
      for (final item in first['items'] as List) {
        for (final hash in item['hashes'] as List) {
          await c.repo.receive(await a.repo.revision(hash as String));
        }
      }
      expect(
        (await c.local.read('messages', 'message'))!.payload['row']['content'],
        '原文',
      );
      await a.local.execute(
        "UPDATE messages SET status='sending' WHERE id='message'",
      );
      final sending = await a.repo.recentChanges();
      expect(identical(second['items'], sending['items']), isFalse);
    },
  );

  test('manifest batches only selected page heads in one query', () async {
    final expected = <String, List<String>>{};
    await a.local.db.transaction(() async {
      for (var i = 0; i < 201; i++) {
        final id = 'manifest-${i.toString().padLeft(3, '0')}';
        final heads = [conflictRevision(id, 'b'), conflictRevision(id, 'a')];
        if (i == 0) heads.add(heads.first);
        await storeConflict(a, heads);
        expected[id] = heads.map((head) => head.hash).toList();
      }
    });
    final local = a.local as LanCountingLocalStore;
    local.revisionQueries.clear();
    final page = await a.repo.manifest(limit: 200);
    expect(page['has_more'], true);
    expect(page['total'], 201);
    expect(page['after'], 'messages/manifest-199');
    final items = page['items'] as List;
    expect(items, hasLength(200));
    for (final item in items) {
      expect(item['hashes'], expected[item['entity_id']]);
    }
    expect(local.revisionQueries, hasLength(1));
    expect(
      local.revisionQueries.single.$1,
      matches(
        RegExp(r'SELECT\s+hash\s*,\s*document_json', caseSensitive: false),
      ),
    );
    expect(local.revisionQueries.single.$2, hasLength(400));
    expect(
      local.revisionQueries.single.$2.toSet(),
      expected.values.take(200).expand((hashes) => hashes).toSet(),
    );
    local.revisionQueries.clear();
    final next = await a.repo.manifest(after: page['after'] as String);
    expect((next['items'] as List).single['entity_id'], 'manifest-200');
    expect(next['has_more'], false);
    expect(next.containsKey('total'), false);
    expect(local.revisionQueries.single.$2, expected['manifest-200']);
  });
  test(
    'manifest isolates damaged head lists and revisions and warns',
    () async {
      final badLists = <String, String>{
        'bad-json': '{',
        'bad-shape': '{}',
        'bad-type': '[1]',
      };
      for (final id in [
        'good',
        ...badLists.keys,
        'missing',
        'malformed',
        'checksum',
        'unsupported',
      ]) {
        await storeConflict(a, [conflictRevision(id, 'a')]);
      }
      for (final entry in badLists.entries) {
        await a.local.execute(
          'UPDATE lan_entities SET heads_json=? WHERE entity_id=?',
          [entry.value, entry.key],
        );
      }
      await a.local.execute('DELETE FROM lan_revisions WHERE hash=?', [
        conflictRevision('missing', 'a').hash,
      ]);
      await a.local.execute(
        'UPDATE lan_revisions SET document_json=? WHERE hash=?',
        ['{', conflictRevision('malformed', 'a').hash],
      );
      final invalid = conflictRevision('checksum', 'a').toJson();
      invalid['deleted'] = true;
      await a.local.execute(
        'UPDATE lan_revisions SET document_json=? WHERE hash=?',
        [jsonEncode(invalid), conflictRevision('checksum', 'a').hash],
      );
      await storeConflict(a, [
        LanRevision(
          kind: 'messages',
          id: 'unsupported',
          vector: {'a': 1},
          payload: {
            'client_schema': 999,
            'row': {'id': 'unsupported'},
          },
        ),
      ]);
      final local = a.local as LanCountingLocalStore;
      local.revisionQueries.clear();
      final before = AppLogger.entries.value.length;
      final page = await a.repo.manifest();
      expect((page['items'] as List).single['entity_id'], 'good');
      expect(page['total'], 8);
      expect(page['after'], 'messages/unsupported');
      expect(page['has_more'], false);
      expect(local.revisionQueries, hasLength(1));
      expect(
        AppLogger.entries.value
            .skip(before)
            .where((e) => e.level == LogLevel.warning)
            .map((e) => e.metadata?['entity_id'])
            .toSet(),
        {...badLists.keys, 'missing', 'malformed', 'checksum', 'unsupported'},
      );
    },
  );
  test('manifest hides sending heads but retains page cursor', () async {
    final sent = conflictRevision('mixed', 'a');
    LanRevision sending(String id) => LanRevision(
      kind: 'messages',
      id: id,
      vector: {'b': 1},
      payload: {
        ...conflictRevision(id, 'b').payload,
        'row': {
          ...conflictRevision(id, 'b').payload['row'] as Map,
          'status': 'sending',
        },
      },
    );
    await storeConflict(a, [sent, sending('mixed')]);
    await storeConflict(a, [sending('sending-only')]);
    final page = await a.repo.manifest(limit: 1);
    expect((page['items'] as List).single['hashes'], [sent.hash]);
    expect(page['has_more'], true);
    final next = await a.repo.manifest(
      after: page['after'] as String,
      limit: 1,
    );
    expect(next['items'], isEmpty);
    expect(next['after'], 'messages/sending-only');
    expect(next['has_more'], false);
    final local = a.local as LanCountingLocalStore;
    local.revisionQueries.clear();
    final empty = await a.repo.manifest(after: next['after'] as String);
    expect(empty['items'], isEmpty);
    expect(empty['after'], next['after']);
    expect(local.revisionQueries, isEmpty);
  });
  test(
    'missing deduplicates and queries cold hashes in batches of 200',
    () async {
      final heads = [
        for (var i = 0; i < 205; i++) conflictRevision('missing-$i', 'a'),
      ];
      for (final head in heads.take(3)) {
        await storeConflict(a, [head]);
      }
      await a.repo.revision(heads.first.hash);
      final local = a.local as LanCountingLocalStore;
      local.revisionQueries.clear();
      final hashes = heads.map((head) => head.hash).toList();
      expect(
        await a.repo.missing([...hashes, ...hashes, heads.first.hash]),
        hashes.skip(3),
      );
      expect(local.revisionQueries.map((q) => q.$2.length), [200, 4]);
      expect(
        local.revisionQueries.every(
          (q) => RegExp(
            r'SELECT\s+hash\s+FROM',
            caseSensitive: false,
          ).hasMatch(q.$1),
        ),
        true,
      );
      local.revisionQueries.clear();
      expect(
        await a.repo.missing([heads.first.hash, heads.first.hash]),
        isEmpty,
      );
      expect(local.revisionQueries, isEmpty);
    },
  );
  test(
    'conflicts reads while capture waits on external IO outside a transaction',
    () async {
      final heads = [
        conflictRevision('snapshot', 'a'),
        conflictRevision('snapshot', 'b'),
      ];
      await storeConflict(a, heads);
      final local = a.local as LanCountingLocalStore;
      final entered = local.externalEntered = Completer<void>();
      final release = local.externalRelease = Completer<void>();
      final capture = a.repo.capture();
      try {
        // Reaching external() proves capture has entered the real serial lane.
        await entered.future;
        final conflicts = await a.repo.conflicts().timeout(
          const Duration(seconds: 2),
        );
        expect(conflicts.single.map((r) => r.hash), heads.map((r) => r.hash));
        expect(release.isCompleted, false);
      } finally {
        release.complete();
        await capture;
      }
    },
  );
  test(
    'cold conflicts deduplicates all heads into batches of at most 200',
    () async {
      final expected = <String, List<String>>{};
      await a.local.db.transaction(() async {
        for (var i = 0; i < 102; i++) {
          final heads = [
            conflictRevision('batch-$i', 'b'),
            conflictRevision('batch-$i', 'a'),
          ];
          if (i == 0) heads.add(heads.first);
          await storeConflict(a, heads);
          expected[heads.first.id] = heads.map((r) => r.hash).toList();
        }
      });
      final local = a.local as LanCountingLocalStore;
      local.revisionQueries.clear();
      final conflicts = await a.repo.conflicts();
      expect(conflicts, hasLength(102));
      for (final heads in conflicts) {
        expect(heads.map((r) => r.hash), expected[heads.first.id]);
      }
      expect(local.revisionQueries.map((q) => q.$2.length), [200, 4]);
      expect(
        local.revisionQueries.every(
          (q) => RegExp(
            r'SELECT\s+hash\s*,\s*document_json',
            caseSensitive: false,
          ).hasMatch(q.$1),
        ),
        true,
      );
      expect(local.revisionQueries.expand((q) => q.$2).toSet(), hasLength(204));
    },
  );
  test(
    'revision cache reuses only identical persisted documents and never missing rows',
    () async {
      final heads = [
        conflictRevision('cached', 'a'),
        conflictRevision('cached', 'b'),
      ];
      await storeConflict(a, heads);
      final first = (await a.repo.conflicts()).single;
      final warm = (await a.repo.conflicts()).single;
      expect(identical(first.first, warm.first), true);
      expect(identical(first.last, warm.last), true);
      expect(
        identical(await a.repo.revision(heads.first.hash), first.first),
        true,
      );
      await a.local
          .execute('UPDATE lan_revisions SET document_json=? WHERE hash=?', [
            const JsonEncoder.withIndent('  ').convert(heads.first.toJson()),
            heads.first.hash,
          ]);
      final rewritten = (await a.repo.conflicts()).single;
      expect(identical(first.first, rewritten.first), false);
      expect(identical(first.last, rewritten.last), true);
      await a.local.execute('DELETE FROM lan_revisions WHERE hash=?', [
        heads.first.hash,
      ]);
      expect(await a.repo.conflicts(), isEmpty);
      await expectLater(
        a.repo.revision(heads.first.hash),
        throwsA(isA<LanSyncFailure>()),
      );
    },
  );
  test(
    'revision cache keeps 2048 entries and evicts the least recently read',
    () async {
      await a.local.db.transaction(() async {
        for (var i = 0; i < 1024; i++) {
          await storeConflict(a, [
            conflictRevision('lru-$i', 'a'),
            conflictRevision('lru-$i', 'b'),
          ]);
        }
      });
      final original = (await a.repo.conflicts()).first;
      final touched = original.first, oldest = original.last;
      expect(identical(await a.repo.revision(touched.hash), touched), true);
      final extra = conflictRevision('lru-extra', 'a');
      await storeConflict(a, [extra]);
      await a.repo.revision(extra.hash);
      expect(identical(await a.repo.revision(touched.hash), touched), true);
      expect(identical(await a.repo.revision(oldest.hash), oldest), false);
    },
  );
  test('revision cache bounds retained UTF-8 documents to 32 MiB', () async {
    // Eleven 3 MiB documents exceed the byte budget but not the entry limit.
    // Multibyte text also catches accidentally counting Dart string length.
    final content = '界' * (1024 * 1024);
    final revisions = <LanRevision>[];
    await a.local.db.transaction(() async {
      for (var i = 0; i < 11; i++) {
        final original = conflictRevision('bytes-$i', 'a');
        final revision = LanRevision(
          kind: original.kind,
          id: original.id,
          vector: original.vector,
          payload: {
            ...original.payload,
            'row': {...original.payload['row'] as Map, 'content': content},
          },
        );
        revisions.add(revision);
        await storeConflict(a, [revision]);
      }
    });
    final first = await a.repo.revision(revisions.first.hash);
    LanRevision? last;
    for (final revision in revisions.skip(1)) {
      last = await a.repo.revision(revision.hash);
    }
    expect(identical(await a.repo.revision(revisions.last.hash), last), true);
    expect(
      identical(await a.repo.revision(revisions.first.hash), first),
      false,
    );
  });
  test(
    'saving an incoming revision does not cache the caller object',
    () async {
      await seedLan(a);
      final incoming = conflictRevision('received', 'peer');
      await a.repo.receive(incoming);
      expect(identical(await a.repo.revision(incoming.hash), incoming), false);
    },
  );
  for (final blocked in ['future schema', 'unknown column', 'sending']) {
    test(
      'conflict-warmed revision cache still checks $blocked at the send entrance',
      () async {
        final original = conflictRevision('blocked', 'a');
        final blockedHead = LanRevision(
          kind: original.kind,
          id: original.id,
          vector: original.vector,
          payload: {
            ...original.payload,
            if (blocked == 'future schema') 'client_schema': 23,
            'row': {
              ...original.payload['row'] as Map,
              if (blocked == 'unknown column') 'future_column': null,
              if (blocked == 'sending') 'status': 'sending',
            },
          },
        );
        await storeConflict(a, [blockedHead, conflictRevision('blocked', 'b')]);
        expect(await a.repo.conflicts(), hasLength(1));
        await expectLater(
          a.repo.revision(blockedHead.hash),
          throwsA(
            blocked == 'sending'
                ? isA<LanSyncFailure>()
                : isA<CloudSyncFailure>(),
          ),
        );
      },
    );
  }
  test(
    'missing, malformed and checksum-invalid heads skip only their entity and warn',
    () async {
      for (final id in ['good', 'missing', 'malformed', 'checksum']) {
        await storeConflict(a, [
          conflictRevision(id, 'a'),
          conflictRevision(id, 'b'),
        ]);
      }
      // Warm the cache before changing persisted documents.
      await a.repo.conflicts();
      await a.local.execute('DELETE FROM lan_revisions WHERE hash=?', [
        conflictRevision('missing', 'a').hash,
      ]);
      await a.local.execute(
        'UPDATE lan_revisions SET document_json=? WHERE hash=?',
        ['{', conflictRevision('malformed', 'a').hash],
      );
      final invalid = conflictRevision('checksum', 'a').toJson();
      invalid['deleted'] = true;
      await a.local.execute(
        'UPDATE lan_revisions SET document_json=? WHERE hash=?',
        [jsonEncode(invalid), conflictRevision('checksum', 'a').hash],
      );
      final before = AppLogger.entries.value.length;
      expect((await a.repo.conflicts()).single.first.id, 'good');
      expect(
        AppLogger.entries.value
            .skip(before)
            .where((e) => e.level == LogLevel.warning)
            .map((e) => e.metadata?['entity_id'])
            .toSet(),
        {'missing', 'malformed', 'checksum'},
      );
    },
  );
  test(
    'pending conversation deletion remains visible in head order without duplicate heads',
    () async {
      await seedLan(a);
      await a.repo.capture();
      final stored = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='conversations'",
      )).single;
      final current = await a.repo.revision(
        (jsonDecode(stored['heads_json'] as String) as List).single as String,
      );
      final deleted = LanRevision(
        kind: current.kind,
        id: current.id,
        vector: {'offline': 1},
        payload: current.payload,
        deleted: true,
      );
      await a.local.execute(
        'INSERT INTO lan_pending_deletions(hash,peer_id,document_json) VALUES(?,?,?)',
        [deleted.hash, 'offline', canonicalJson(deleted.toJson())],
      );
      final conflicts = (await a.repo.conflicts()).single;
      expect(conflicts.map((r) => r.hash), [current.hash, deleted.hash]);
      expect(conflicts.last.deleted, true);
      expect(
        identical((await a.repo.conflicts()).single.last, conflicts.last),
        true,
      );
      expect(
        await a.local.rows('SELECT * FROM lan_pending_deletions'),
        hasLength(1),
      );
      // A tombstone already present in the regular heads is not shown twice.
      await storeConflict(a, [current, deleted]);
      expect((await a.repo.conflicts()).single.map((r) => r.hash), [
        current.hash,
        deleted.hash,
      ]);
      await a.local.execute(
        "DELETE FROM messages WHERE conversation_id='role'",
      );
      await storeConflict(a, [current]);
      expect(await a.repo.conflicts(), isEmpty);
      expect(
        await a.local.rows('SELECT * FROM lan_pending_deletions'),
        hasLength(1),
      );
    },
  );
  for (final unsupported in ['future schema', 'unknown column']) {
    test(
      'receive rejects $unsupported before saving a same-content or conflicting head',
      () async {
        await seedLan(a);
        await a.repo.capture();
        final entity = (await a.local.rows(
          "SELECT * FROM lan_entities WHERE kind='messages'",
        )).single;
        final original = await a.repo.revision(
          (jsonDecode(entity['heads_json'] as String) as List).single as String,
        );
        final incoming = LanRevision(
          kind: original.kind,
          id: original.id,
          vector: {'future-peer': 1},
          payload: {
            ...original.payload,
            if (unsupported == 'future schema') 'client_schema': 23,
            if (unsupported == 'unknown column')
              'row': {...original.payload['row'] as Map, 'future_column': null},
          },
          mediaIds: original.mediaIds,
        );
        final before = await a.local.rows('SELECT * FROM lan_entities');
        final revisions = await a.local.rows('SELECT hash FROM lan_revisions');
        final counter = await a.local.rows('SELECT counter FROM lan_state');
        await expectLater(
          a.repo.receive(incoming),
          throwsA(isA<CloudSyncFailure>()),
        );
        expect(await a.local.rows('SELECT * FROM lan_entities'), before);
        expect(await a.local.rows('SELECT hash FROM lan_revisions'), revisions);
        expect(await a.local.rows('SELECT counter FROM lan_state'), counter);
      },
    );
    test(
      'capture skips persisted $unsupported without normalization or propagation',
      () async {
        await seedLan(a);
        await a.repo.capture();
        final entity = (await a.local.rows(
          "SELECT * FROM lan_entities WHERE kind='messages'",
        )).single;
        final original = await a.repo.revision(
          (jsonDecode(entity['heads_json'] as String) as List).single as String,
        );
        final incoming = LanRevision(
          kind: original.kind,
          id: original.id,
          vector: {'future-peer': 1},
          payload: {
            ...original.payload,
            if (unsupported == 'future schema') 'client_schema': 23,
            if (unsupported == 'unknown column')
              'row': {...original.payload['row'] as Map, 'future_column': null},
          },
          mediaIds: original.mediaIds,
        );
        await a.local.execute(
          'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
          [
            incoming.hash,
            incoming.kind,
            incoming.id,
            canonicalJson(incoming.toJson()),
          ],
        );
        await a.local.execute(
          "UPDATE lan_entities SET heads_json=? WHERE kind='messages'",
          [
            jsonEncode([
              if (unsupported == 'future schema') original.hash,
              incoming.hash,
            ]),
          ],
        );
        await a.local.execute(
          "INSERT INTO lan_dirty(kind,entity_id) VALUES('messages','message')",
        );
        final before = await a.local.rows('SELECT * FROM lan_entities');
        final revisions = await a.local.rows('SELECT hash FROM lan_revisions');
        final counter = await a.local.rows('SELECT counter FROM lan_state');
        await a.repo.capture();
        expect(
          await a.local.rows("SELECT * FROM lan_dirty WHERE kind='messages'"),
          isEmpty,
        );
        expect(await a.local.rows('SELECT * FROM lan_entities'), before);
        expect(await a.local.rows('SELECT hash FROM lan_revisions'), revisions);
        expect(await a.local.rows('SELECT counter FROM lan_state'), counter);
        await expectLater(
          a.repo.revision(incoming.hash),
          throwsA(isA<CloudSyncFailure>()),
        );
        final manifest = await a.repo.manifest();
        expect(
          (manifest['items'] as List).where(
            (item) => item['kind'] == 'messages',
          ),
          isEmpty,
        );
        final recent = await a.repo.recentChanges();
        expect(
          (recent['items'] as List).where((item) => item['kind'] == 'messages'),
          isEmpty,
        );
      },
    );
  }
  for (final fingerprintSchema in [null, 1]) {
    test(
      'legacy fingerprint upgrades without revision (schema $fingerprintSchema)',
      () async {
        await seedLan(a);
        await a.repo.capture();
        final current = (await a.local.read('messages', 'message'))!;
        final old = (await a.local.rows(
          "SELECT * FROM lan_entities WHERE kind='messages'",
        )).single;
        final head = await a.repo.revision(
          (jsonDecode(old['heads_json'] as String) as List).single as String,
        );
        final legacy = LanRevision(
          kind: head.kind,
          id: head.id,
          vector: head.vector,
          payload: {...head.payload, 'client_schema': 1},
          mediaIds: head.mediaIds,
        );
        await a.local.execute(
          'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
          [legacy.hash, legacy.kind, legacy.id, canonicalJson(legacy.toJson())],
        );
        final oldFingerprint = cloudObjectId(
          canonicalJson({
            'payload': {
              ...current.payload,
              if (fingerprintSchema != null) 'client_schema': fingerprintSchema,
            },
          }),
        );
        await a.local.execute(
          "UPDATE lan_entities SET heads_json=?,local_fingerprint=? WHERE kind='messages'",
          [
            jsonEncode([legacy.hash]),
            oldFingerprint,
          ],
        );
        await a.local.execute(
          "DELETE FROM cloud_local_migrations WHERE name='lan_content_fingerprint_v1_queued'",
        );
        // A missing migration marker is observed when the repository starts.
        a = LanTestDevice(
          a.local,
          a.media,
          LanRepository(
            a.local,
            CloudMediaCodec(a.media, allowNetworkDownload: false),
            'a',
          ),
        );
        final before = await a.local.rows('SELECT counter FROM lan_state');
        final revisions = await a.local.rows('SELECT hash FROM lan_revisions');
        await a.repo.capture();
        final after = (await a.local.rows(
          "SELECT * FROM lan_entities WHERE kind='messages'",
        )).single;
        expect(after['heads_json'], jsonEncode([legacy.hash]));
        expect(after['local_fingerprint'], isNot(oldFingerprint));
        expect(await a.local.rows('SELECT counter FROM lan_state'), before);
        expect(await a.local.rows('SELECT hash FROM lan_revisions'), revisions);
        await a.repo.capture();
        expect(await a.local.rows('SELECT counter FROM lan_state'), before);
      },
    );
  }
  test(
    'first capture queues persisted schema conflicts and converges without a write',
    () async {
      await seedLan(a);
      await a.repo.capture();
      final entity = (await a.local.rows(
        "SELECT * FROM lan_entities WHERE kind='messages'",
      )).single;
      final head = await a.repo.revision(
        (jsonDecode(entity['heads_json'] as String) as List).single as String,
      );
      final other = LanRevision(
        kind: head.kind,
        id: head.id,
        vector: {'old-peer': 1},
        payload: {...head.payload, 'client_schema': 1},
        mediaIds: head.mediaIds,
      );
      await a.local.execute(
        'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
        [other.hash, other.kind, other.id, canonicalJson(other.toJson())],
      );
      await a.local.execute(
        "UPDATE lan_entities SET heads_json=? WHERE kind='messages'",
        [
          jsonEncode([head.hash, other.hash]),
        ],
      );
      await a.local.execute(
        "DELETE FROM cloud_local_migrations WHERE name='lan_content_fingerprint_v1_queued'",
      );
      // A missing migration marker is observed when the repository starts.
      a = LanTestDevice(
        a.local,
        a.media,
        LanRepository(
          a.local,
          CloudMediaCodec(a.media, allowNetworkDownload: false),
          'a',
        ),
      );
      final before = await a.local.rows('SELECT counter FROM lan_state');
      await a.repo.capture();
      expect(await a.repo.conflicts(), isEmpty);
      final after = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages'",
      )).single;
      final joined = await a.repo.revision(
        (jsonDecode(after['heads_json'] as String) as List).single as String,
      );
      expect(joined.vector, joinLanVectors([head.vector, other.vector]));
      expect(joined.payload['client_schema'], head.payload['client_schema']);
      expect(await a.local.rows('SELECT counter FROM lan_state'), before);
      expect(
        await a.local.rows(
          "SELECT name FROM cloud_local_migrations WHERE name='lan_content_fingerprint_v1_queued'",
        ),
        hasLength(1),
      );
      await a.repo.capture();
      expect(await a.local.rows('SELECT counter FROM lan_state'), before);
    },
  );
  test(
    'capture applies a newly mergeable setting head without incrementing counter',
    () async {
      await seedLan(a);
      await a.repo.capture();
      final entity = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='conversations'",
      )).single;
      final head = await a.repo.revision(
        (jsonDecode(entity['heads_json'] as String) as List).single as String,
      );
      final other = LanRevision(
        kind: head.kind,
        id: head.id,
        vector: {'old-peer': 1},
        payload: {
          ...head.payload,
          'client_schema': 1,
          'row': {...head.payload['row'] as Map, 'title': 'merged title'},
          'setting_times': {
            ...head.payload['setting_times'] as Map,
            'title': {'at_ms': 253402300799000, 'device_id': 'old-peer'},
          },
        },
      );
      await a.local.execute(
        'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
        [other.hash, other.kind, other.id, canonicalJson(other.toJson())],
      );
      await a.local.execute(
        "UPDATE lan_entities SET heads_json=? WHERE kind='conversations'",
        [
          jsonEncode([head.hash, other.hash]),
        ],
      );
      await a.local.execute(
        "DELETE FROM cloud_local_migrations WHERE name='lan_content_fingerprint_v1_queued'",
      );
      // A missing migration marker is observed when the repository starts.
      a = LanTestDevice(
        a.local,
        a.media,
        LanRepository(
          a.local,
          CloudMediaCodec(a.media, allowNetworkDownload: false),
          'a',
        ),
      );
      final before = await a.local.rows('SELECT counter FROM lan_state');
      final local = a.local as LanCountingLocalStore;
      local.beforeExecute = (sql, args) async {
        if (sql.startsWith('INSERT INTO "conversations"')) {
          throw const CloudSyncFailure('设置保存失败，稍后继续同步');
        }
      };
      await expectLater(a.repo.capture(), throwsA(isA<CloudSyncFailure>()));
      local.beforeExecute = null;
      expect(
        await a.local.rows(
          "SELECT * FROM lan_dirty WHERE kind='conversations'",
        ),
        hasLength(1),
      );
      expect(
        (await a.local.rows(
          'SELECT suspended FROM lan_state',
        )).single['suspended'],
        0,
      );
      await a.repo.capture();
      expect(
        (await a.local.read('conversations', 'role'))!.payload['row']['title'],
        'merged title',
      );
      expect(await a.repo.conflicts(), isEmpty);
      expect(await a.local.rows('SELECT counter FROM lan_state'), before);
      await a.repo.capture();
      expect(await a.local.rows('SELECT counter FROM lan_state'), before);
    },
  );
  test(
    'legacy fingerprint migration retains a real offline message edit',
    () async {
      await seedLan(a);
      await a.repo.capture();
      final current = (await a.local.read('messages', 'message'))!;
      final originalEntity = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages'",
      )).single;
      final original = await a.repo.revision(
        (jsonDecode(originalEntity['heads_json'] as String) as List).single
            as String,
      );
      final legacyHead = LanRevision(
        kind: original.kind,
        id: original.id,
        vector: {'old-peer': 1},
        payload: {...original.payload, 'client_schema': 1},
      );
      await a.local.execute(
        'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
        [
          legacyHead.hash,
          legacyHead.kind,
          legacyHead.id,
          canonicalJson(legacyHead.toJson()),
        ],
      );
      await a.local.execute(
        "UPDATE lan_entities SET heads_json=? WHERE kind='messages'",
        [
          jsonEncode([original.hash, legacyHead.hash]),
        ],
      );
      final fingerprint = cloudObjectId(
        canonicalJson({
          'payload': {...current.payload, 'client_schema': 1},
        }),
      );
      await a.local.execute(
        "UPDATE lan_entities SET local_fingerprint=? WHERE kind='messages'",
        [fingerprint],
      );
      final before =
          (await a.local.rows(
                'SELECT counter FROM lan_state',
              )).single['counter']
              as int;
      await a.local.execute(
        "UPDATE messages SET content='offline edit' WHERE id='message'",
      );
      await a.repo.capture();
      final entity = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages'",
      )).single;
      final head = await a.repo.revision(
        (jsonDecode(entity['heads_json'] as String) as List).single as String,
      );
      expect(head.payload['row']['content'], 'offline edit');
      expect(head.vector['old-peer'], 1);
      expect(
        (await a.local.rows('SELECT counter FROM lan_state')).single['counter'],
        before + 1,
      );
    },
  );
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
  test('an unreadable entity is skipped instead of failing conflicts', () async {
    final bad = ['b' * 64, 'c' * 64];
    for (final hash in bad) {
      await a.local.execute(
        'INSERT INTO lan_revisions(hash,kind,entity_id,document_json) VALUES(?,?,?,?)',
        [hash, 'messages', 'broken', '{"kind":"messages"}'],
      );
    }
    await a.local.execute(
      'INSERT INTO lan_entities(kind,entity_id,heads_json,local_fingerprint) VALUES(?,?,?,?)',
      ['messages', 'broken', jsonEncode(bad), 'x'],
    );
    expect(await a.repo.conflicts(), isEmpty);
  });
  test('resolving a legacy head drops device-local General fields', () async {
    const key = 'aicove.ui_models.v1';
    await saveCloudPreference(
      a.local.preferences,
      key,
      jsonEncode({'frosted_tint_fill': 0.2}),
      atMs: 1000,
    );
    LanRevision legacy(String device, Map<String, dynamic> value) =>
        LanRevision(
          kind: 'settings',
          id: cloudObjectId('preference:$key'),
          vector: {device: 1},
          payload: {
            'storage': 'preference',
            'key': key,
            'json_value': jsonEncode(value),
            'setting_times_version': 1,
            'setting_times': <String, dynamic>{},
          },
        );
    final dirty = legacy('old', {
      'active_model': 'x',
      'frosted_tint_fill': 0.9,
    });
    await a.repo.receive(dirty);
    await a.repo.receive(legacy('phone', {'active_model': 'y'}));
    final conflict = (await a.repo.conflicts()).single;
    await a.repo.resolve(
      'settings',
      dirty.id,
      dirty.hash,
      conflict.map((r) => r.hash).toList(),
    );
    final row = (await a.local.rows(
      'SELECT heads_json FROM lan_entities WHERE kind=? AND entity_id=?',
      ['settings', dirty.id],
    )).single;
    final head = await a.repo.revision(
      (jsonDecode(row['heads_json'] as String) as List).single as String,
    );
    expect(jsonDecode(head.payload['json_value'] as String), {
      'active_model': 'x',
    });
    expect(
      (head.payload['setting_times'] as Map).keys,
      isNot(contains('frosted_tint_fill')),
    );
    expect(
      jsonDecode(a.local.preferences.getString(key)!)['frosted_tint_fill'],
      0.2,
    );
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
  test(
    'message deletion and conflict resolution notify onMessageApplied instead of generic messages kind',
    () async {
      final appliedKinds = <String>{};
      final messageEvents = <(String, String, int)>[];
      final repo = LanRepository(
        a.local,
        CloudMediaCodec(a.media, allowNetworkDownload: false),
        'a',
        onApplied: appliedKinds.addAll,
        onMessageApplied: (convId, msgId, createdAt) =>
            messageEvents.add((convId, msgId, createdAt)),
      );
      await seedLan(a);
      await repo.capture();
      final stored = (await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages'",
      )).single;
      final base = await repo.revision(
        (jsonDecode(stored['heads_json'] as String) as List).single as String,
      );
      final remoteDelete = LanRevision(
        kind: 'messages',
        id: 'message',
        vector: {...base.vector, 'b': 1},
        payload: base.payload,
        deleted: true,
      );
      await repo.receive(remoteDelete);
      expect(messageEvents, [('role', 'message', 1)]);
      expect(appliedKinds, isNot(contains('messages')));

      messageEvents.clear();
      appliedKinds.clear();
      await b.local.execute(
        'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
        ['role', '角色', '角色', 1, 1],
      );
      await a.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload) VALUES(?,?,?,?,?,?)',
        ['conflict_msg', 'role', 'assistant', '原文', 1, '{"text":"原文"}'],
      );
      await repo.capture();
      for (final item in (await repo.manifest())['items'] as List) {
        for (final hash in await b.repo.missing(
          (item['hashes'] as List).cast<String>(),
        )) {
          await b.repo.receive(await repo.revision(hash));
        }
      }
      await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'a编辑',
        'conflict_msg',
      ]);
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'b编辑',
        'conflict_msg',
      ]);
      await repo.capture();
      await b.repo.capture();
      for (final item in (await b.repo.manifest())['items'] as List) {
        for (final hash in await repo.missing(
          (item['hashes'] as List).cast<String>(),
        )) {
          await repo.receive(await b.repo.revision(hash));
        }
      }
      final conflict = (await repo.conflicts()).single;
      final chosen = conflict.firstWhere(
        (r) => r.payload['row']['content'] == 'b编辑',
      );
      messageEvents.clear();
      appliedKinds.clear();
      await repo.resolve(
        'messages',
        'conflict_msg',
        chosen.hash,
        conflict.map((r) => r.hash).toList(),
      );
      expect(messageEvents, [('role', 'conflict_msg', 1)]);
      expect(appliedKinds, isNot(contains('messages')));
    },
  );
}
