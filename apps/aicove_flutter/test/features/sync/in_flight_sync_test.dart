import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'lan_repository_test.dart' show LanTestDevice, lanTestDevice, seedLan;

/// In-memory receipts only: no HTTP server, account, or model requests.
class _CloudReceipts implements CloudRemote {
  final mutations = <Map<String, dynamic>>[];
  final incoming = <Map<String, dynamic>>[];
  Future<void> Function()? beforeReceipt;
  var sequence = 0;

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
      final changes = incoming.toList();
      incoming.clear();
      return {
        'through': sequence,
        'next_cursor': sequence,
        'has_more': false,
        'changes': changes,
      };
    }
    throw StateError('Unexpected fixture GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path != 'push') throw StateError('Unexpected fixture POST $path');
    final results = <Map<String, dynamic>>[];
    for (final raw in body['mutations'] as List) {
      final mutation = Map<String, dynamic>.from(raw as Map);
      mutations.add(mutation);
      results.add({
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
      });
    }
    final callback = beforeReceipt;
    beforeReceipt = null;
    await callback?.call();
    return {'results': results};
  }

  @override
  void close() {}
  @override
  Future<void> upload(String digest, File file) =>
      throw StateError('Unexpected media upload');
  @override
  Future<void> uploadBatch(Map<String, File> files) =>
      throw StateError('Unexpected media upload');
  @override
  Future<void> download(String digest, File target) =>
      throw StateError('Unexpected media download');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LanTestDevice a, b;
  late _CloudReceipts remote;
  late CloudSyncEngine cloud;
  final progress = <CloudProgress>[];

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('aicove-in-flight-sync-');
    a = await lanTestDevice(root, 'a');
    b = await lanTestDevice(root, 'b');
    remote = _CloudReceipts();
    progress.clear();
    cloud = CloudSyncEngine(
      a.local,
      remote,
      a.media,
      'fixture',
      onProgress: progress.add,
    );
    await a.local.execute(
      "UPDATE cloud_client_state SET enabled=1,initialized=1,"
      "mode='source',epoch='fixture',account_key='fixture' WHERE id=1",
    );
    await seedLan(a);
    // Finish the existing one-time migration before comparing dirty revisions.
    await a.local.prepareMessageSnapshots();
  });

  tearDown(() async {
    await cloud.waitForMedia();
    cloud.close();
    for (final device in [a, b]) {
      await device.media.close();
      await device.local.db.close();
    }
    await root.delete(recursive: true);
  });

  Future<void> status(String value, {String role = 'user'}) => a.local.execute(
    'UPDATE messages SET status=?,role=? WHERE id=?',
    [value, role, 'message'],
  );

  Future<List<Map<String, dynamic>>> dirty(
    LanTestDevice d,
    String channel,
  ) => d.local.rows(
    "SELECT * FROM ${channel}_dirty WHERE kind='messages' ORDER BY entity_id",
  );

  Future<void> syncCloud() async {
    await cloud.synchronize();
    await cloud.waitForMedia();
    expect(progress.where((p) => p.error != null), isEmpty);
  }

  /// Same capture -> paged manifest -> missing -> revision -> receive sequence
  /// as LanService, including incremental capture on subsequent remote pages.
  Future<void> copy(LanTestDevice from, LanTestDevice to) async {
    var after = '';
    do {
      await from.repo.capture(scanExternal: after.isEmpty);
      final page = await from.repo.manifest(after: after, limit: 1);
      for (final item in page['items'] as List) {
        final hashes = (item['hashes'] as List).cast<String>();
        for (final hash in await to.repo.missing(hashes)) {
          await to.repo.receive(await from.repo.revision(hash));
        }
        expect(await to.repo.missing(hashes), isEmpty);
      }
      if (page['has_more'] != true) return;
      final next = page['after'] as String;
      expect(next.compareTo(after), greaterThan(0));
      after = next;
    } while (true);
  }

  for (final terminal in ['sent', 'failed']) {
    test(
      'sending stays local, then $terminal completes both channels',
      () async {
        await status('sending');
        final cloudBefore = await dirty(a, 'cloud');
        final lanBefore = await dirty(a, 'lan');
        expect(cloudBefore, hasLength(1));
        expect(lanBefore, hasLength(1));

        await syncCloud();
        await copy(a, b);
        await copy(b, a);
        expect(remote.mutations.where((m) => m['kind'] == 'messages'), isEmpty);
        expect(await b.local.read('messages', 'message'), isNull);
        expect(await dirty(a, 'cloud'), cloudBefore);
        expect(await dirty(a, 'lan'), lanBefore);
        expect(
          await a.local.rows(
            "SELECT * FROM lan_revisions WHERE kind='messages'",
          ),
          isEmpty,
        );
        expect(await a.local.rows('SELECT * FROM cloud_outbox'), isEmpty);

        await status(terminal);
        final cloudPending = await dirty(a, 'cloud');
        await copy(a, b);
        await copy(b, a);
        expect(
          (await b.local.read('messages', 'message'))!.payload['row']['status'],
          terminal,
        );
        expect(await dirty(a, 'lan'), isEmpty);
        expect(await dirty(b, 'lan'), isEmpty);
        expect(await dirty(a, 'cloud'), cloudPending);
        await syncCloud();
        final sent = remote.mutations
            .where((m) => m['kind'] == 'messages')
            .single;
        expect(sent['action'], 'put');
        expect(sent['payload']['row']['status'], terminal);
        expect(sent['payload']['message_snapshot_version'], 1);
        expect(await dirty(a, 'cloud'), isEmpty);
      },
    );
  }

  test('assistant sending is also deferred', () async {
    await status('sending', role: 'assistant');
    await syncCloud();
    await copy(a, b);
    expect(remote.mutations.where((m) => m['kind'] == 'messages'), isEmpty);
    expect(await b.local.read('messages', 'message'), isNull);
    expect(await dirty(a, 'cloud'), hasLength(1));
    expect(await dirty(a, 'lan'), hasLength(1));
  });

  test('retrying a known message does not publish a deletion', () async {
    await status('sent');
    await syncCloud();
    await copy(a, b);
    final revisions = await a.local.rows('SELECT * FROM lan_revisions');
    remote.mutations.clear();
    await status('sending');
    final cloudBefore = await dirty(a, 'cloud');
    final lanBefore = await dirty(a, 'lan');
    await syncCloud();
    await copy(a, b);
    expect(remote.mutations, isEmpty);
    expect(await a.local.rows('SELECT * FROM lan_revisions'), revisions);
    expect(await dirty(a, 'cloud'), cloudBefore);
    expect(await dirty(a, 'lan'), lanBefore);
    expect(
      (await b.local.read('messages', 'message'))!.payload['row']['status'],
      'sent',
    );
  });

  test('targeted capture keeps a local sending edit before receive', () async {
    await status('sent');
    await copy(a, b);
    final payload = (await a.local.read('messages', 'message'))!.payload;
    await status('sending');
    final before = await dirty(a, 'lan');
    await expectLater(
      a.repo.receive(
        LanRevision(
          kind: 'messages',
          id: 'message',
          vector: {'remote': 1},
          payload: payload,
        ),
      ),
      throwsA(isA<LanSyncFailure>()),
    );
    expect(await dirty(a, 'lan'), before);
    expect(
      (await a.local.read('messages', 'message'))!.payload['row']['status'],
      'sending',
    );
    final stored = await a.local.rows(
      "SELECT document_json FROM lan_revisions WHERE kind='messages'",
    );
    expect(stored, hasLength(1));
    expect(
      jsonDecode(
        stored.single['document_json'] as String,
      )['payload']['row']['status'],
      'sent',
    );
  });

  test('an actual deletion still reaches cloud and LAN', () async {
    await status('sent');
    await syncCloud();
    await copy(a, b);
    remote.mutations.clear();
    await status('sending');
    await a.local.execute("DELETE FROM messages WHERE id='message'");
    await syncCloud();
    await copy(a, b);
    expect(remote.mutations.single['action'], 'delete');
    expect(await b.local.read('messages', 'message'), isNull);
    expect(await dirty(a, 'lan'), isEmpty);
    expect(await dirty(a, 'cloud'), isEmpty);
  });

  test('sending rows cannot starve the 500-row incremental capture', () async {
    await a.repo.capture();
    await a.local.db.transaction(() async {
      for (var i = 0; i < 501; i++) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,status)'
          " VALUES(?,'role','user','in flight',1,'sending')",
          ['a-${i.toString().padLeft(3, '0')}'],
        );
      }
      await a.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at,status)'
        " VALUES('z-ready','role','user','ready',1,'sent')",
      );
    });
    final before = await a.local.rows(
      "SELECT * FROM lan_dirty WHERE entity_id LIKE 'a-%' ORDER BY entity_id",
    );
    await a.repo.capture(scanExternal: false);
    expect(
      await a.local.rows(
        "SELECT * FROM lan_entities WHERE entity_id='z-ready'",
      ),
      hasLength(1),
    );
    expect(await dirty(a, 'lan'), before);
    await copy(a, b);
    expect(await b.local.read('messages', 'z-ready'), isNotNull);
    expect(
      await b.local.rows("SELECT id FROM messages WHERE status='sending'"),
      isEmpty,
    );
  });

  test(
    'receiver pruning keeps an unchanged legacy sending dirty row',
    () async {
      await status('sending');
      final document = (await a.local.read('messages', 'message'))!;
      await a.local.execute(
        "UPDATE cloud_client_state SET mode='receive' WHERE id=1",
      );
      await a.local.execute('INSERT INTO cloud_versions VALUES(?,?,?,?,?,?)', [
        'messages',
        'message',
        1,
        document.localJson,
        '{}',
        null,
      ]);
      final before = await dirty(a, 'cloud');
      await a.local.pruneUnchangedReceiverEdits();
      expect(await dirty(a, 'cloud'), before);
    },
  );

  test('cloud receipt cannot clear a newer sending revision', () async {
    await status('sent');
    remote.beforeReceipt = () => status('sending');
    await syncCloud();
    expect(await dirty(a, 'cloud'), hasLength(1));
    final before = await dirty(a, 'cloud');
    remote.mutations.clear();
    await syncCloud();
    expect(remote.mutations, isEmpty);
    expect(await dirty(a, 'cloud'), before);
  });

  test(
    'legacy cloud sending is applied and not confirmed as a local edit',
    () async {
      await status('sending');
      final document = (await a.local.read('messages', 'message'))!;
      await a.local.execute('DELETE FROM messages WHERE id=?', ['message']);
      await a.local.execute("DELETE FROM cloud_dirty WHERE kind='messages'");
      remote.incoming.add({
        'kind': 'messages',
        'entity_id': 'message',
        'version': 1,
        'seq': ++remote.sequence,
        'deleted': false,
        'payload_version': 1,
        'payload': document.payload,
        'media_ids': <String>[],
      });
      await syncCloud();
      expect(
        (await a.local.read('messages', 'message'))!.payload['row']['status'],
        'sending',
      );
      await a.local.mark('messages', 'message');
      final before = await dirty(a, 'cloud');
      remote.incoming.add({
        'kind': 'messages',
        'entity_id': 'message',
        'version': 2,
        'seq': ++remote.sequence,
        'deleted': false,
        'payload_version': 1,
        'payload': document.payload,
        'media_ids': <String>[],
      });
      await syncCloud();
      expect(await dirty(a, 'cloud'), before);
      expect(remote.mutations.where((m) => m['kind'] == 'messages'), isEmpty);
    },
  );

  test('legacy LAN sending is accepted but not advertised or relayed', () async {
    await status('sending');
    await copy(a, b); // Conversation only.
    final payload = (await a.local.read('messages', 'message'))!.payload;
    final incoming = LanRevision(
      kind: 'messages',
      id: 'message',
      vector: {'legacy': 1},
      payload: payload,
    );
    await b.repo.receive(incoming);
    expect(
      (await b.local.read('messages', 'message'))!.payload['row']['status'],
      'sending',
    );
    expect(await b.repo.missing([incoming.hash]), isEmpty);
    await b.local.execute(
      'INSERT INTO messages(id,conversation_id,role,content,created_at,status)'
      " VALUES('z-visible','role','user','ready',2,'sent')",
    );
    await b.repo.capture(scanExternal: false);
    final manifest = await b.repo.manifest(
      after: 'conversations/role',
      limit: 1,
    );
    expect(manifest['items'], isEmpty);
    expect(manifest['after'], 'messages/message');
    expect(manifest['has_more'], true);
    final next = await b.repo.manifest(
      after: manifest['after'] as String,
      limit: 1,
    );
    expect((next['items'] as List).single['entity_id'], 'z-visible');
    expect(next['has_more'], false);
    await expectLater(
      b.repo.revision(incoming.hash),
      throwsA(isA<LanSyncFailure>()),
    );

    // A terminal update from that same old peer still supersedes its sending.
    await b.repo.receive(
      LanRevision(
        kind: 'messages',
        id: 'message',
        vector: {'legacy': 2},
        payload: {
          ...payload,
          'row': {...payload['row'] as Map, 'status': 'sent'},
        },
      ),
    );
    final hashes =
        jsonDecode(
              (await b.local.rows(
                    "SELECT heads_json FROM lan_entities WHERE kind='messages' AND entity_id='message'",
                  )).single['heads_json']
                  as String,
            )
            as List;
    expect(
      (await b.repo.revision(hashes.single as String)).payload['row']['status'],
      'sent',
    );
  });

  test(
    'legacy sending recovery still uses the strict 30-minute threshold',
    () async {
      await status('sending');
      final payload = (await a.local.read('messages', 'message'))!.payload;
      await copy(a, b);
      await b.repo.receive(
        LanRevision(
          kind: 'messages',
          id: 'message',
          vector: {'legacy': 1},
          payload: payload,
        ),
      );
      var now = DateTime.fromMillisecondsSinceEpoch(
        1,
      ).add(kInterruptedSendRecoveryThreshold);
      final messages = MessageRepository(b.local.db, now: () => now);
      expect(
        await messages.recoverInterruptedUserMessages(
          'role',
          isActiveSend: (_) => false,
        ),
        isEmpty,
      );
      now = now.add(const Duration(milliseconds: 1));
      expect(
        await messages.recoverInterruptedUserMessages(
          'role',
          isActiveSend: (_) => true,
        ),
        isEmpty,
      );
      expect(
        await messages.recoverInterruptedUserMessages(
          'role',
          isActiveSend: (_) => false,
        ),
        ['message'],
      );
      await b.repo.capture();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['status'],
        'failed',
      );
      expect(await dirty(b, 'lan'), isEmpty);
    },
  );
}
