import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/context/application/context_manager.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/context/domain/context_summary.dart';
import 'package:aicove_flutter/src/features/memory/application/memory_keeper_service.dart';
import 'package:aicove_flutter/src/features/memory/data/sqlite_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_api.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_sync_engine.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_service.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'lan_service_test.dart' show LanTestDiscovery;
import 'lan_transport_test.dart' show LanMemoryCredentials;
import 'package:aicove_flutter/src/features/voice_call/data/voice_call_context_brief.dart';
import 'package:flutter_test/flutter_test.dart';
import 'lan_repository_test.dart' as fixture;

class Summarizer implements ContextSummarizerPort {
  int calls = 0;
  @override
  Future<String> summarize(
    ContextSnapshot snapshot, {
    required ContextSummaryKind kind,
    required void Function(int, int) onProgress,
    required bool Function() isCancelled,
  }) async {
    calls++;
    return '通话简报';
  }
}

class OldCloud implements CloudRemote {
  bool upgraded = false;
  int sequence = 0;
  final sent = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    if (path == 'status') {
      return {
        'epoch': 'test',
        'cursor': sequence,
        'media_version': 1,
        'message_snapshot_version': 1,
        'media_usage_version': 1,
        'kinds': [
          'conversations',
          'messages',
          'providers',
          'settings',
          'plugin_presets',
          if (upgraded) ...lanContextMemoryKinds,
        ],
      };
    }
    if (path == 'pull') {
      return {
        'through': sequence,
        'next_cursor': sequence,
        'has_more': false,
        'changes': [],
      };
    }
    throw StateError(path);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path != 'push') throw StateError(path);
    return {
      'results': [
        for (final raw in body['mutations'] as List)
          receipt(Map<String, dynamic>.from(raw as Map)),
      ],
    };
  }

  Map<String, dynamic> receipt(Map<String, dynamic> mutation) {
    final kind = mutation['kind'] as String;
    if (!upgraded && lanContextMemoryKinds.contains(kind)) {
      throw StateError('old server rejected $kind');
    }
    sent.add(kind);
    return {
      'op_id': mutation['op_id'],
      'status': 'applied',
      'document': {
        'kind': kind,
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
  Future<void> upload(String digest, File file) async =>
      throw StateError('upload');
  @override
  Future<void> uploadBatch(Map<String, File> files) async =>
      throw StateError('upload');
  @override
  Future<void> download(String digest, File target) async =>
      throw StateError('download');
}

void main() {
  late Directory root;
  late fixture.LanTestDevice a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('context-memory-sync-');
    a = await fixture.lanTestDevice(root, 'a');
    b = await fixture.lanTestDevice(root, 'b');
  });
  tearDown(() async {
    await a.media.close();
    await b.media.close();
    await a.local.db.close();
    await b.local.db.close();
    await root.delete(recursive: true);
  });

  test(
    'LAN copies summaries, voice brief and searchable memory in parent order',
    () async {
      await a.local.execute(
        'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
        ['role', '角色', '角色', 1, 1],
      );
      final messages = [
        for (var i = 0; i < 12; i++)
          Message(
            id: 'm$i',
            role: i.isEven ? 'user' : 'assistant',
            content: '内容$i',
            status: 'sent',
            createdAt: DateTime.fromMillisecondsSinceEpoch(i + 1),
          ),
      ];
      for (final m in messages) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,status) VALUES(?,?,?,?,?,?)',
          [
            m.id,
            'role',
            m.role,
            m.content,
            m.createdAt.millisecondsSinceEpoch,
            m.status,
          ],
        );
      }
      Future<List<Message>> load(String _) async => messages;
      final storeA = SqliteContextSummaryStore(a.local.db, load);
      final manualSnapshot = await storeA.manualSnapshot('role');
      final manual = await storeA.commitManual(manualSnapshot, '手动摘要');
      final autoSnapshot = ContextSnapshot(
        ownerId: 'role',
        previousBoundaryId: manual.boundaryId,
        allMessages: messages,
        messages: messages.take(3).toList(),
        previous: null,
      );
      await storeA.saveAuto(autoSnapshot, '自动摘要');
      // Use a separate conversation window, so the auto summary does not cover the brief.
      await a.local.execute(
        'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
        ['voice', '语音', '语音', 1, 1],
      );
      for (final m in messages) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,status) VALUES(?,?,?,?,?,?)',
          [
            'v${m.id}',
            'voice',
            m.role,
            m.content,
            m.createdAt.millisecondsSinceEpoch,
            m.status,
          ],
        );
      }
      final voiceMessages = [
        for (final m in messages)
          Message(
            id: 'v${m.id}',
            role: m.role,
            content: m.content,
            createdAt: m.createdAt,
            status: m.status,
          ),
      ];
      Future<List<Message>> loadAll(String owner) async =>
          owner == 'voice' ? voiceMessages : messages;
      final voiceStoreA = SqliteContextSummaryStore(a.local.db, loadAll);
      final conversation = Conversation(
        id: 'voice',
        title: '语音',
        displayName: '语音',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
      final summaryModel = Summarizer();
      final split = splitVoiceCallWindow(voiceMessages);
      expect(
        await VoiceCallContextBrief(
          store: voiceStoreA,
          summarizer: () async => summaryModel,
        ).build(conversation, voiceMessages, split.earlier),
        '通话简报',
      );
      final memoryA = SqliteMemoryStore(a.local.db);
      await memoryA.saveByUser(
        ownerId: 'role',
        layer: MemoryLayer.core,
        title: '喜欢',
        content: '喜欢喝桂花茶',
      );
      await memoryA.applyAgentOps(
        'role',
        [],
        processedUntil: messages.last,
        generation: 0,
      );
      await a.local.execute("UPDATE memory_items SET embedding=x'010203'");
      final memoryDoc = await a.local.read(
        'memory_items',
        (await memoryA.list('role')).single.id,
      );
      expect((memoryDoc!.payload['row'] as Map)['embedding'], isNull);
      await a.repo.capture();
      final legacyRecent = await a.repo.recentChangesForPeer(
        includeContextMemory: false,
      );
      expect(
        (legacyRecent['items'] as List).where(
          (e) => lanContextMemoryKinds.contains(e['kind']),
        ),
        isEmpty,
      );
      final oldPage = await a.repo.manifest(after: '');
      expect(
        (oldPage['items'] as List).where(
          (e) => lanContextMemoryKinds.contains(e['kind']),
        ),
        isEmpty,
      );
      var after = '';
      final seen = <String>[];
      do {
        final page = await a.repo.manifestForPeer(
          after: after,
          limit: 2,
          includeContextMemory: true,
        );
        for (final item in page['items'] as List) {
          seen.add(item['kind'] as String);
          for (final hash in (item['hashes'] as List).cast<String>()) {
            await b.repo.receive(await a.repo.revision(hash));
          }
        }
        final next = page['after'] as String;
        if (page['has_more'] != true) break;
        expect(
          compareLanManifestCursors(next, after, includeContextMemory: true),
          greaterThan(0),
        );
        after = next;
      } while (true);
      expect(
        seen.indexOf('conversations'),
        lessThan(seen.indexOf('context_summaries')),
      );
      final storeB = SqliteContextSummaryStore(b.local.db, loadAll);
      final manager = ContextManager(
        store: storeB,
        loadMessages: loadAll,
        readBoundary: (_) async => manual.boundaryId,
        summarizerFactory: () async => throw StateError('must not resummarize'),
        publishBoundary: (_) async {},
        ensureIdle: (_) {},
      );
      expect(
        (await manager.manualSummary(
          'role',
          manual.boundaryId,
          const [],
        ))?.summary,
        '手动摘要',
      );
      expect(
        (await manager.loadAuto('role', manual.boundaryId, messages))?.summary,
        '自动摘要',
      );
      expect(
        await VoiceCallContextBrief(
          store: storeB,
          summarizer: () async => throw StateError('must reuse brief'),
        ).build(conversation, voiceMessages, split.earlier),
        '通话简报',
      );
      expect(await storeB.listHistory('voice'), isEmpty);
      expect(await storeB.compactedBoundaries('voice'), isEmpty);
      final memoryB = SqliteMemoryStore(b.local.db);
      expect(
        (await memoryB.searchKeyword('role', '桂花茶')).single.content,
        '喜欢喝桂花茶',
      );
      final memoryRow = await a.local.read(
        'memory_items',
        (await memoryA.list('role')).single.id,
      );
      await b.local.apply(
        'memory_items',
        memoryRow!.id,
        {},
        true,
      );
      expect(await memoryB.searchKeyword('role', '桂花茶'), isEmpty);
      await b.local.apply(
        'memory_items',
        memoryRow.id,
        memoryRow.payload,
        false,
      );
      expect(await memoryB.searchKeyword('role', '桂花茶'), hasLength(1));
      final keeper = MemoryKeeperService(
        store: memoryB,
        loadMessages: loadAll,
        compactedBoundaries: storeB.compactedBoundaries,
        agentFactory: () async => throw StateError('must not run'),
        allowed: (_) async => true,
      );
      expect(await keeper.pendingMessages('role'), isEmpty);
    },
  );

  test('LAN 媒体块跨设备改写路径后直接命中手动与自动摘要，不重跑模型', () async {
    await fixture.seedLan(a);
    final png = img.encodePng(img.Image(width: 1, height: 1));
    final image = File('${root.path}/image.png')..writeAsBytesSync(png);
    final audio = File('${root.path}/audio.wav')
      ..writeAsBytesSync(List.filled(64, 0));
    final emoji = File('${root.path}/emoji.png')..writeAsBytesSync(png);
    final blocks = <MessageBlock>[
      EmojiBlock(
        id: 'e',
        messageId: 'message',
        emojiId: 'emoji',
        path: emoji.path,
        matchedTag: '开心',
      ),
      AudioBlock(
        id: 'a',
        messageId: 'message',
        url: audio.path,
        text: '你好',
        unread: true,
      ),
      ImageBlock(
        id: 'i',
        messageId: 'message',
        localPath: image.path,
        prompt: '海边',
      ),
    ];
    for (var i = 0; i < blocks.length; i++) {
      await a.local.db
          .into(a.local.db.messageBlocks)
          .insert(MessageBlockConverter.toCompanion(blocks[i], 'message', i));
    }
    Future<List<Message>> load(fixture.LanTestDevice device, String _) async {
      final messages = await device.local.db
          .select(device.local.db.messages)
          .get();
      final rows = await device.local.db
          .select(device.local.db.messageBlocks)
          .get();
      rows.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      return [
        for (final m in messages)
          MessageConverter.fromDb(
            m,
            blocks: [
              for (final row in rows.where((b) => b.messageId == m.id))
                MessageBlockConverter.fromDb(row)!,
            ],
          ),
      ];
    }

    final storeA = SqliteContextSummaryStore(
      a.local.db,
      (owner) => load(a, owner),
    );
    final snapshot = await storeA.manualSnapshot('role');
    final manual = await storeA.commitManual(snapshot, '媒体手动摘要');
    final autoSnapshot = ContextSnapshot(
      ownerId: 'role',
      previousBoundaryId: manual.boundaryId,
      allMessages: snapshot.allMessages,
      messages: snapshot.messages,
      previous: null,
    );
    final auto = await storeA.saveAuto(autoSnapshot, '媒体自动摘要');
    await a.repo.capture();
    await for (final record in a.media.records()) {
      await b.media.receive(record.asset, now: DateTime.now(), download: false);
    }
    final page = await a.repo.manifestForPeer(
      after: '',
      includeContextMemory: true,
    );
    for (final item in page['items'] as List) {
      for (final hash in (item['hashes'] as List).cast<String>()) {
        await b.repo.receive(await a.repo.revision(hash));
      }
    }
    final received = await load(b, 'role');
    expect(received.single.blocks, hasLength(3));
    expect(
      received.single.blocks!.whereType<EmojiBlock>().single.path,
      isNot(emoji.path),
    );
    expect(
      received.single.blocks!.whereType<AudioBlock>().single.url,
      isNot(audio.path),
    );
    expect(
      received.single.blocks!.whereType<ImageBlock>().single.localPath,
      isNot(image.path),
    );
    final storeB = SqliteContextSummaryStore(
      b.local.db,
      (owner) => load(b, owner),
    );
    var modelRequests = 0;
    final manager = ContextManager(
      store: storeB,
      loadMessages: (owner) => load(b, owner),
      readBoundary: (_) async => manual.boundaryId,
      summarizerFactory: () async {
        modelRequests++;
        throw StateError('must reuse');
      },
      publishBoundary: (_) async {},
      ensureIdle: (_) {},
    );
    expect(
      (await manager.manualSummary('role', manual.boundaryId, []))?.id,
      manual.id,
    );
    expect(
      (await manager.loadAuto('role', manual.boundaryId, received))?.id,
      auto.id,
    );
    expect(modelRequests, 0);
  });

  test('paired LAN negotiates old listings and syncs an empty device', () async {
    await fixture.seedLan(a);
    await a.local.execute(
      "INSERT INTO context_summaries(id,owner_id,kind,boundary_id,summary,source_ids,source_digest,created_at) VALUES('summary','role','manual','message','summary','[]','digest',1)",
    );
    await a.local.execute(
      "INSERT INTO memory_items(id,owner_id,layer,title,content,created_at,updated_at) VALUES('memory','role','core','茶','桂花茶',1,1)",
    );
    await a.local.execute(
      "INSERT INTO memory_progress(owner_id,until_at,until_id,updated_at) VALUES('role',1,'message',1)",
    );
    final sa = LanService(
      a.repo,
      LanPeerStore(LanMemoryCredentials(), loopback: true),
      discovery: LanTestDiscovery(),
      loopback: true,
      automatic: false,
    );
    final sb = LanService(
      b.repo,
      LanPeerStore(LanMemoryCredentials(), loopback: true),
      discovery: LanTestDiscovery(),
      loopback: true,
      automatic: false,
    );
    try {
      await sa.initialize();
      await sb.initialize();
      await sa.setEnabled(true);
      await sb.setEnabled(true);
      await sa.invite();
      await sb.pair(sa.state.invitation!);
      await sa.approve('b');
      await a.repo.capture();
      final peer = sb.peers.peers['a']!;
      final status = await sb.transport.rpc(peer, {'method': 'status'});
      expect(status['context_memory_sync'], 1);
      for (final method in ['recent', 'manifest']) {
        final legacy = await sb.transport.rpc(peer, {'method': method});
        expect(
          (legacy['items'] as List).where(
            (e) => lanContextMemoryKinds.contains(e['kind']),
          ),
          isEmpty,
        );
        final modern = await sb.transport.rpc(peer, {
          'method': method,
          'context_memory_sync': 1,
        });
        expect(
          (modern['items'] as List).any(
            (e) => lanContextMemoryKinds.contains(e['kind']),
          ),
          isTrue,
        );
      }
      await sb.synchronize();
      expect(sb.state.error, isNull);
      expect(
        await b.local.rows('SELECT id FROM context_summaries'),
        hasLength(1),
      );
      expect(await b.local.rows('SELECT id FROM memory_items'), hasLength(1));
      expect(
        await b.local.rows('SELECT owner_id FROM memory_progress'),
        hasLength(1),
      );
      expect(
        await SqliteMemoryStore(b.local.db).searchKeyword('role', '桂花茶'),
        hasLength(1),
      );
    } finally {
      await sa.close();
      await sb.close();
    }
  });

  test('old cloud skips new kinds until the server upgrades', () async {
    await fixture.seedLan(a);
    await a.local.execute(
      "INSERT INTO memory_progress(owner_id,until_at,until_id,updated_at) VALUES('role',1,'message',1)",
    );
    await a.local.execute(
      "UPDATE cloud_client_state SET enabled=1,initialized=1,mode='source',epoch='test',account_key='test' WHERE id=1",
    );
    final remote = OldCloud();
    final reports = <CloudProgress>[];
    final engine = CloudSyncEngine(
      a.local,
      remote,
      a.media,
      'test',
      onProgress: reports.add,
    );
    await engine.synchronize();
    expect(reports.last.error, isNull);
    expect(remote.sent, contains('messages'));
    expect(remote.sent, isNot(contains('memory_progress')));
    expect(
      await a.local.rows(
        "SELECT 1 FROM cloud_dirty WHERE kind='memory_progress'",
      ),
      isNotEmpty,
    );
    expect(
      await a.local.rows(
        "SELECT 1 FROM cloud_outbox WHERE kind='memory_progress'",
      ),
      isEmpty,
    );
    remote.upgraded = true;
    await engine.synchronize();
    expect(reports.last.error, isNull);
    expect(remote.sent, contains('memory_progress'));
    await engine.waitForMedia();
    engine.close();
  });

  test('orphan rows and unknown payloads fail safely', () async {
    final doc = {
      'client_schema': 22,
      'row': {'owner_id': 'missing', 'generation': 0, 'updated_at': 1},
    };
    await expectLater(
      b.local.apply('memory_progress', 'missing', doc, false),
      throwsA(isA<CloudSyncFailure>()),
    );
    await expectLater(
      b.local.apply('future_kind', 'id', {}, false),
      throwsA(isA<CloudSyncFailure>()),
    );
  });

  test('progress heads choose greatest generation then latest bookmark', () {
    LanRevision revision(String device, int generation, int? until) =>
        LanRevision(
          kind: 'memory_progress',
          id: 'role',
          vector: {device: 1},
          payload: {
            'client_schema': 22,
            'row': {
              'owner_id': 'role',
              'generation': generation,
              'until_at': until,
              'until_id': '$until',
              'updated_at': 1,
            },
          },
        );
    final merged = reduceLanHeads([
      revision('a', 1, 500),
      revision('b', 2, null),
      revision('c', 2, 600),
    ]).single;
    expect((merged.payload['row'] as Map)['until_at'], 600);
    expect(merged.vector.keys, containsAll(['a', 'b', 'c']));
  });
}
