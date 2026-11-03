import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/core/sync/cloud_local_write.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';

import 'lan_repository_test.dart'
    show LanMemoryPreferences, LanTestDevice, lanTestDevice, seedLan, copyLan;

class _InterleavingStore extends CloudLocalStore {
  _InterleavingStore(
    super.db,
    super.preferences,
    super.documents,
    super.support,
  );

  String? interleaveKind;
  Future<void> Function()? interleave;
  Future<void>? pendingWrite;

  @override
  Future<CloudLocalDocument?> read(
    String kind,
    String id, {
    bool includeRelated = true,
  }) async {
    final result = await super.read(kind, id, includeRelated: includeRelated);
    if (kind == interleaveKind && includeRelated && interleave != null) {
      final action = interleave!;
      interleave = null;
      // Model an independent user operation, not a reentrant write belonging
      // to the sync operation's Zone/SQLite transaction.
      pendingWrite = Zone.root.run(() => cloudLocalWrite(action));
      await Future<void>.delayed(Duration.zero);
    }
    return result;
  }
}

class _Receipts implements CloudRemote {
  final sent = <Map<String, dynamic>>[];
  final incoming = <Map<String, dynamic>>[];
  Future<void> Function()? beforePull;
  int sequence = 100;

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
        'setting_times_version': 1,
      };
    }
    if (path == 'pull') {
      final action = beforePull;
      beforePull = null;
      await action?.call();
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
    return {
      'results': [
        for (final raw in body['mutations'] as List)
          _receipt(Map<String, dynamic>.from(raw as Map)),
      ],
    };
  }

  Map<String, dynamic> _receipt(Map<String, dynamic> mutation) {
    sent.add(mutation);
    return {
      'op_id': mutation['op_id'],
      'status': 'applied',
      'document': {
        'kind': mutation['kind'],
        'entity_id': mutation['entity_id'],
        'version': (mutation['base_version'] as int) + 1,
        'seq': ++sequence,
        'deleted': mutation['action'] == 'delete',
        'payload_version': 1,
        'payload': mutation['payload'],
        'media_ids': mutation['media_ids'],
      },
    };
  }

  @override
  void close() {}
  @override
  Future<void> upload(String digest, File file) =>
      throw StateError('Unexpected upload');
  @override
  Future<void> uploadBatch(Map<String, File> files) =>
      throw StateError('Unexpected upload');
  @override
  Future<void> download(String digest, File target) =>
      throw StateError('Unexpected download');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _InterleavingStore local;
  late MediaStore media;
  late LanRepository lan;
  late LanTestDevice peer;
  late _Receipts remote;
  late CloudSyncEngine cloud;
  final progress = <CloudProgress>[];

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = Directory('test/features/sync/.sync-integrity-tmp');
    await root.create(recursive: true);
    root = await root.createTemp('run-');
    local = _InterleavingStore(
      AppDatabase.forTesting(NativeDatabase.memory()),
      LanMemoryPreferences(),
      Directory('${root.path}/docs')..createSync(),
      Directory('${root.path}/support')..createSync(),
    );
    await local.execute('PRAGMA foreign_keys=ON');
    media = MediaStore(Directory('${root.path}/media'), 'a');
    lan = LanRepository(
      local,
      CloudMediaCodec(media, allowNetworkDownload: false),
      'a',
    );
    peer = await lanTestDevice(root, 'b');
    remote = _Receipts();
    progress.clear();
    cloud = CloudSyncEngine(
      local,
      remote,
      media,
      'fixture',
      onProgress: progress.add,
    );
    await local.execute(
      "UPDATE cloud_client_state SET enabled=1,initialized=1,mode='source',epoch='fixture',account_key='fixture' WHERE id=1",
    );
    await seedLan(LanTestDevice(local, media, lan));
    await local.prepareMessageSnapshots();
  });

  tearDown(() async {
    await local.pendingWrite;
    await cloud.waitForMedia();
    cloud.close();
    await media.close();
    await local.db.close();
    await peer.media.close();
    await peer.local.db.close();
    await root.delete(recursive: true);
    final parent = root.parent;
    if (await parent.exists() && await parent.list().isEmpty) {
      await parent.delete();
    }
  });

  Future<void> sync() async {
    await cloud.synchronize();
    await cloud.waitForMedia();
    expect(progress.where((p) => p.error != null).map((p) => p.error), isEmpty);
  }

  test(
    'upload freezes conversation content and field clocks before encoding',
    () async {
      await local.execute(
        "UPDATE conversations SET title='before' WHERE id='role'",
      );
      await local.execute(
        "UPDATE cloud_setting_times SET at_ms=10 WHERE kind='conversations' AND field='title'",
      );
      remote.beforePull = () async {
        local.interleaveKind = 'conversations';
        local.interleave = () async {
          await local.execute(
            "UPDATE conversations SET title='after' WHERE id='role'",
          );
          await local.execute(
            "UPDATE cloud_setting_times SET at_ms=20 WHERE kind='conversations' AND field='title'",
          );
        };
      };
      await sync();
      await local.pendingWrite;
      final first = remote.sent.firstWhere(
        (m) => m['kind'] == 'conversations',
      )['payload'];
      expect(first['row']['title'], 'before');
      expect(first['setting_times']['title']['at_ms'], 10);
      await sync();
      final last = remote.sent.lastWhere(
        (m) => m['kind'] == 'conversations',
      )['payload'];
      expect(last['row']['title'], 'after');
      expect(last['setting_times']['title']['at_ms'], 20);
    },
  );

  test(
    'upload freezes preference content with its matching clock journal',
    () async {
      const key = 'aicove.ui_models.v1';
      await saveCloudPreference(
        local.preferences,
        key,
        '{"active_model":"before"}',
        atMs: 10,
      );
      remote.beforePull = () async {
        local.interleaveKind = 'settings';
        local.interleave = () => saveCloudPreference(
          local.preferences,
          key,
          '{"active_model":"after"}',
          atMs: 20,
        );
      };
      await sync();
      await local.pendingWrite;
      final first = remote.sent.firstWhere(
        (m) => m['kind'] == 'settings',
      )['payload'];
      expect(
        jsonDecode(first['json_value'] as String)['active_model'],
        'before',
      );
      expect(first['setting_times']['active_model']['at_ms'], 10);
      await sync();
      final last = remote.sent.lastWhere(
        (m) => m['kind'] == 'settings',
      )['payload'];
      expect(jsonDecode(last['json_value'] as String)['active_model'], 'after');
      expect(last['setting_times']['active_model']['at_ms'], 20);
    },
  );

  test(
    'retained messages defer a cloud hard deletion without blocking the inbox batch',
    () async {
      await sync();
      final conversation = (await local.read('conversations', 'role'))!;
      final message = (await local.read('messages', 'message'))!;
      final other = {
        ...conversation.payload,
        'row': {...conversation.payload['row'] as Map, 'id': 'other'},
      };
      remote.incoming.addAll([
        {
          'kind': 'conversations',
          'entity_id': 'role',
          'version': 2,
          'seq': ++remote.sequence,
          'deleted': true,
          'payload': conversation.payload,
        },
        {
          'kind': 'conversations',
          'entity_id': 'other',
          'version': 1,
          'seq': ++remote.sequence,
          'deleted': false,
          'payload': other,
        },
      ]);
      await sync();
      expect(await local.read('conversations', 'role'), isNotNull);
      expect(await local.read('conversations', 'other'), isNotNull);
      expect(
        await local.rows(
          "SELECT * FROM cloud_inbox WHERE kind='conversations' AND entity_id='role'",
        ),
        hasLength(1),
      );
      remote.incoming.add({
        'kind': 'messages',
        'entity_id': 'message',
        'version': 2,
        'seq': ++remote.sequence,
        'deleted': true,
        'payload': message.payload,
      });
      await sync();
      expect(await local.read('messages', 'message'), isNull);
      expect(await local.read('conversations', 'role'), isNull);
      expect(await local.rows('SELECT * FROM cloud_inbox'), isEmpty);
    },
  );

  test(
    'a conversation tombstone left only with unsent local messages does not spin in the inbox',
    () async {
      await sync();
      final conversation = (await local.read('conversations', 'role'))!;
      final message = (await local.read('messages', 'message'))!;
      // Offline, this device writes a new message into the conversation that
      // another device has already deleted.
      await local.execute(
        "CREATE TEMP TABLE fresh_message AS SELECT * FROM messages WHERE id='message'",
      );
      await local.execute("UPDATE fresh_message SET id='fresh'");
      await local.execute('INSERT INTO messages SELECT * FROM fresh_message');
      await local.execute('DROP TABLE fresh_message');
      final sentBefore = remote.sent.length;
      remote.incoming.addAll([
        {
          'kind': 'messages',
          'entity_id': 'message',
          'version': 2,
          'seq': ++remote.sequence,
          'deleted': true,
          'payload': message.payload,
        },
        {
          'kind': 'conversations',
          'entity_id': 'role',
          'version': 2,
          'seq': ++remote.sequence,
          'deleted': true,
          'payload': conversation.payload,
        },
      ]);
      await sync();
      expect(await local.read('messages', 'message'), isNull);
      expect(await local.read('messages', 'fresh'), isNotNull);
      expect(await local.read('conversations', 'role'), isNotNull);
      expect(await local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      await sync();
      expect(await local.rows('SELECT * FROM cloud_inbox'), isEmpty);
      expect(
        remote.sent.skip(sentBefore).where(
          (m) => m['kind'] == 'conversations' && m['entity_id'] == 'role',
        ),
        isNotEmpty,
      );
    },
  );

  Future<List<LanRevision>> conflict() async {
    await copyLan(LanTestDevice(local, media, lan), peer);
    await local.execute(
      "UPDATE messages SET content='ours' WHERE id='message'",
    );
    await peer.local.execute(
      "UPDATE messages SET content='theirs' WHERE id='message'",
    );
    await copyLan(peer, LanTestDevice(local, media, lan));
    return (await lan.conflicts()).single;
  }

  for (final sending in [false, true]) {
    test(
      'resolve rejects a post-capture ${sending ? 'sending transition' : 'edit'}',
      () async {
        final heads = await conflict();
        final chosen = heads.firstWhere(
          (h) => h.payload['row']['content'] == 'theirs',
        );
        local.interleaveKind = 'messages';
        local.interleave = () => local.execute(
          sending
              ? "UPDATE messages SET status='sending',content='in flight' WHERE id='message'"
              : "UPDATE messages SET content='new edit' WHERE id='message'",
        );
        await expectLater(
          lan.resolve(
            'messages',
            'message',
            chosen.hash,
            heads.map((h) => h.hash).toList(),
          ),
          throwsA(isA<LanSyncFailure>()),
        );
        await local.pendingWrite;
        expect(
          (await local.read('messages', 'message'))!.payload['row']['content'],
          sending ? 'in flight' : 'new edit',
        );
        if (!sending) {
          final captured = (await local.rows(
            "SELECT heads_json FROM lan_entities WHERE kind='messages' AND entity_id='message'",
          )).single;
          final hash =
              (jsonDecode(captured['heads_json'] as String) as List).single
                  as String;
          final revision = await lan.revision(hash);
          expect(revision.payload['row']['content'], 'new edit');
          for (final head in heads) {
            expect(lanDominates(revision.vector, head.vector), true);
          }
        } else {
          expect(
            await local.rows("SELECT * FROM lan_dirty WHERE kind='messages'"),
            hasLength(1),
          );
        }
      },
    );
  }

  test('LAN receive queues relay while cloud is paused', () async {
    await copyLan(LanTestDevice(local, media, lan), peer);
    await local.execute('DELETE FROM cloud_dirty');
    await local.execute('UPDATE cloud_client_state SET enabled=0 WHERE id=1');
    await peer.local.execute(
      "UPDATE messages SET content='peer edit' WHERE id='message'",
    );
    await copyLan(peer, LanTestDevice(local, media, lan));
    final dirty = (await local.rows(
      "SELECT * FROM cloud_dirty WHERE kind='messages' AND entity_id='message'",
    )).single;
    expect(dirty['relay_revision'], dirty['revision']);
    expect(
      dirty['relay_until'] as int,
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
  });

  test('LAN explicit resolution queues own edit while cloud is paused', () async {
    final heads = await conflict();
    await local.execute('DELETE FROM cloud_dirty');
    await local.execute('UPDATE cloud_client_state SET enabled=0 WHERE id=1');
    await lan.resolve(
      'messages',
      'message',
      heads.first.hash,
      heads.map((h) => h.hash).toList(),
    );
    final dirty = (await local.rows(
      "SELECT * FROM cloud_dirty WHERE kind='messages' AND entity_id='message'",
    )).single;
    expect(dirty['relay_revision'], -1);
    expect(dirty['relay_until'], 0);
  });

  test(
    'capture removes only orphan revisions without current or queued dependencies',
    () async {
      final payload = (await local.read('messages', 'message'))!.payload;
      final revisions = <String, LanRevision>{};
      for (final id in [
        'orphan',
        'dirty',
        'cloud',
        'pending',
        'pending-hash',
        'head',
        'baseline',
      ]) {
        final revision = LanRevision(
          kind: 'messages',
          id: id,
          vector: {'a': 1},
          payload: {
            ...payload,
            'row': {...payload['row'] as Map, 'id': id},
          },
        );
        revisions[id] = revision;
        await local.execute('INSERT INTO lan_revisions VALUES(?,?,?,?)', [
          revision.hash,
          revision.kind,
          id,
          canonicalJson(revision.toJson()),
        ]);
      }
      // A sending row is deliberately left dirty by capture.
      await local.execute("INSERT INTO lan_dirty VALUES('messages','dirty',1)");
      await local.mark('messages', 'cloud');
      await local.execute('INSERT INTO lan_pending_deletions VALUES(?,?,?)', [
        revisions['pending']!.hash,
        'offline-peer',
        canonicalJson(revisions['pending']!.toJson()),
      ]);
      // The hash itself remains a root even if old pending metadata disagrees.
      await local.execute('INSERT INTO lan_pending_deletions VALUES(?,?,?)', [
        revisions['pending-hash']!.hash,
        'offline-peer',
        canonicalJson(revisions['pending']!.toJson()),
      ]);
      await local.execute('INSERT INTO lan_entities VALUES(?,?,?,?)', [
        'settings',
        'legacy-root',
        jsonEncode([revisions['head']!.hash]),
        'deleted',
      ]);
      await local.execute('INSERT INTO cloud_versions VALUES(?,?,?,?,?,?)', [
        'messages',
        'baseline',
        1,
        'saved baseline',
        '{}',
        null,
      ]);
      // Keep the dirty-only root outside this capture batch; it need not have a
      // valid revision document to prove the collector respects the journal.
      for (var i = 0; i < 500; i++) {
        await local.execute('INSERT INTO lan_dirty VALUES(?,?,1)', [
          'conversations',
          'queued-$i',
        ]);
      }
      await lan.capture(scanExternal: false);
      final remaining = (await local.rows(
        'SELECT hash FROM lan_revisions',
      )).map((row) => row['hash']).toSet();
      expect(remaining, isNot(contains(revisions['orphan']!.hash)));
      for (final id in [
        'dirty',
        'cloud',
        'pending',
        'pending-hash',
        'head',
        'baseline',
      ]) {
        expect(remaining, contains(revisions[id]!.hash), reason: id);
      }
    },
  );

  test(
    'an offline peer can still request common ancestor and superseded hashes',
    () async {
      await copyLan(LanTestDevice(local, media, lan), peer);
      final before = (await local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages' AND entity_id='message'",
      )).single;
      final ancestor =
          (jsonDecode(before['heads_json'] as String) as List).single as String;
      await local.execute(
        "UPDATE messages SET content='first edit' WHERE id='message'",
      );
      await lan.capture();
      final after = (await local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages' AND entity_id='message'",
      )).single;
      final requested =
          (jsonDecode(after['heads_json'] as String) as List).single as String;
      await local.execute(
        "UPDATE messages SET content='second edit' WHERE id='message'",
      );
      await lan.capture();
      expect((await lan.revision(ancestor)).payload['row']['content'], '原文');
      expect(
        (await lan.revision(requested)).payload['row']['content'],
        'first edit',
      );
      await peer.repo.receive(await lan.revision(requested));
      expect(
        (await peer.local.read(
          'messages',
          'message',
        ))!.payload['row']['content'],
        'first edit',
      );
      await copyLan(LanTestDevice(local, media, lan), peer);
      expect(
        (await peer.local.read(
          'messages',
          'message',
        ))!.payload['row']['content'],
        'second edit',
      );
    },
  );
}
