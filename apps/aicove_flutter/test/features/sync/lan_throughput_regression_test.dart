import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/media/media_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_media_codec.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_service.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lan_repository_test.dart'
    show LanMemoryPreferences, LanTestDevice, copyLan, seedLan;
import 'lan_service_test.dart' show LanTestDiscovery;
import 'lan_transport_test.dart' show LanMemoryCredentials;

class CountingLocalStore extends CloudLocalStore {
  CountingLocalStore(
    super.db,
    super.preferences,
    super.documents,
    super.support,
  );
  int externalScans = 0;

  @override
  Future<List<CloudLocalDocument>> external() {
    externalScans++;
    return super.external();
  }
}

class ObservedLanRepository extends LanRepository {
  ObservedLanRepository(super.local, super.codec, super.deviceId);
  int missingRequests = 0;
  final missingBatchSizes = <int>[];
  bool alreadyHasRevisions = false;
  Map<String, dynamic>? manifestFixture;
  bool holdMessages = false;
  final messageEntered = Completer<void>();
  final resumeMessages = Completer<void>();

  @override
  Future<List<String>> missing(Iterable<String> hashes) {
    missingRequests++;
    missingBatchSizes.add(hashes.length);
    if (alreadyHasRevisions) return Future.value([]);
    return super.missing(hashes);
  }

  @override
  Future<Map<String, dynamic>> manifest({String after = '', int limit = 100}) =>
      manifestFixture != null
      ? Future.value(manifestFixture!)
      : super.manifest(after: after, limit: limit);

  @override
  Future<void> receive(LanRevision incoming) async {
    if (holdMessages && incoming.kind == 'messages') {
      if (!messageEntered.isCompleted) messageEntered.complete();
      await resumeMessages.future;
    }
    await super.receive(incoming);
  }
}

Future<bool> eventually(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  do {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  } while (DateTime.now().isBefore(deadline));
  return false;
}

void main() {
  late Directory root;
  late LanTestDevice a, b;
  late LanService sa, sb;

  Future<LanTestDevice> device(String id) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement('PRAGMA foreign_keys=ON');
    final local = CountingLocalStore(
      database,
      LanMemoryPreferences(),
      Directory('${root.path}/$id/docs')..createSync(recursive: true),
      Directory('${root.path}/$id/support')..createSync(recursive: true),
    );
    final media = MediaStore(Directory('${root.path}/$id/media'), id);
    return LanTestDevice(
      local,
      media,
      ObservedLanRepository(
        local,
        CloudMediaCodec(media, allowNetworkDownload: false),
        id,
      ),
    );
  }

  LanService service(LanTestDevice d) => LanService(
    d.repo,
    LanPeerStore(LanMemoryCredentials(), loopback: true),
    discovery: LanTestDiscovery(),
    loopback: true,
    automatic: false,
  );

  Future<void> connect() async {
    await sa.setEnabled(true);
    await sb.setEnabled(true);
    await sa.invite();
    await sb.pair(sa.state.invitation!);
    await sa.approve('b');
  }

  Future<void> addExternalFixtures(LanTestDevice d) async {
    for (var i = 0; i < 8; i++) {
      await d.local.preferences.setString(
        'aicove.plugins.throughput_$i',
        jsonEncode({'value': i, 'fixture': 'x' * 1024}),
      );
      final preset = File('${d.local.fileRoots['presets']!.path}/$i.json');
      await preset.parent.create(recursive: true);
      await preset.writeAsString(jsonEncode({'fixture': 'x' * 4096}));
    }
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('aicove-lan-throughput-');
    a = await device('a');
    b = await device('b');
    sa = service(a);
    sb = service(b);
    await sa.initialize();
    await sb.initialize();
  });

  tearDown(() async {
    final repo = b.repo as ObservedLanRepository;
    if (!repo.resumeMessages.isCompleted) repo.resumeMessages.complete();
    await sa.close();
    await sb.close();
    for (final d in [a, b]) {
      await d.media.close();
      await d.local.db.close();
    }
    await root.delete(recursive: true);
  });

  test('message receive does not rescan unrelated settings or presets', () async {
    await seedLan(a);
    await copyLan(a, b);
    await addExternalFixtures(b);
    await b.repo.capture();
    final local = b.local as CountingLocalStore;
    local.externalScans = 0;
    final watch = Stopwatch()..start();
    for (var i = 0; i < 30; i++) {
      await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'revision-$i',
        'message',
      ]);
      await a.repo.capture();
      final heads = await a.local.rows(
        "SELECT heads_json FROM lan_entities WHERE kind='messages' AND entity_id='message'",
      );
      final hash =
          (jsonDecode(heads.single['heads_json'] as String) as List).single
              as String;
      await b.repo.receive(await a.repo.revision(hash));
    }
    watch.stop();
    // An operation-count assertion is stable across hosts; timing is diagnostic.
    stdout.writeln(
      'LAN_RECEIVE_BENCHMARK records=30 scans=${local.externalScans} elapsed_ms=${watch.elapsedMilliseconds}',
    );
    expect(local.externalScans, 0);
    expect(
      (await b.local.read('messages', 'message'))!.payload['row']['content'],
      'revision-29',
    );
  });

  test('one full capture enumerates external documents only once', () async {
    await addExternalFixtures(b);
    final local = b.local as CountingLocalStore;
    local.externalScans = 0;
    await b.repo.capture();
    stdout.writeln('LAN_CAPTURE_BENCHMARK scans=${local.externalScans}');
    expect(local.externalScans, 1);
    expect((await b.repo.manifest())['items'], hasLength(17));
  });

  test('target capture preserves unrelated committed dirty messages', () async {
    await seedLan(a);
    await copyLan(a, b);
    await b.local.execute(
      'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
      ['other', 'role', 'assistant', 'unsynced local message', 2],
    );
    await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
      'remote update',
      'message',
    ]);
    await copyLan(a, b);
    expect(
      await b.local.rows(
        "SELECT 1 FROM lan_dirty WHERE kind='messages' AND entity_id='other'",
      ),
      isNotEmpty,
    );
    await b.repo.capture();
    expect(
      await b.local.rows("SELECT 1 FROM lan_entities WHERE entity_id='other'"),
      isNotEmpty,
    );
  });

  test('unchanged history batches missing checks by manifest page', () async {
    await seedLan(a);
    for (var i = 0; i < 205; i++) {
      await a.local.execute(
        'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
        ['bulk-$i', 'role', 'assistant', 'fixture', i + 2],
      );
    }
    await connect();
    await sb.synchronize();
    expect(sb.peers.peers['a']!.error, isNull);
    final remote = a.repo as ObservedLanRepository;
    remote.missingRequests = 0;
    final remoteLocal = a.local as CountingLocalStore;
    remoteLocal.externalScans = 0;
    await sb.synchronize();
    stdout.writeln(
      'LAN_IDLE_BENCHMARK missing_requests=${remote.missingRequests}',
    );
    expect(remote.missingRequests, lessThanOrEqualTo(3));
    stdout.writeln(
      'LAN_PAGE_BENCHMARK external_scans=${remoteLocal.externalScans}',
    );
    expect(remoteLocal.externalScans, 1);
    expect(sb.peers.peers['a']!.error, isNull);
  });

  test('first targeted receive preserves an uncaptured local edit', () async {
    await seedLan(a);
    await seedLan(b);
    await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
      'offline local edit',
      'message',
    ]);
    await copyLan(a, b);
    final conflict = (await b.repo.conflicts()).singleWhere(
      (heads) => heads.first.kind == 'messages',
    );
    expect(conflict, hasLength(2));
    expect(
      (await b.local.read('messages', 'message'))!.payload['row']['content'],
      'offline local edit',
    );
  });

  test(
    'continuation capture still drains a backlog larger than 500 rows',
    () async {
      await seedLan(a);
      for (var i = 0; i < 550; i++) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
          ['backlog-$i', 'role', 'assistant', 'fixture', i + 2],
        );
      }
      await a.repo.capture();
      expect(await a.local.rows('SELECT 1 FROM lan_dirty'), isNotEmpty);
      await a.repo.capture(scanExternal: false);
      expect(await a.local.rows('SELECT 1 FROM lan_dirty'), isEmpty);
      final count = await a.local.rows(
        "SELECT count(*) AS n FROM lan_entities WHERE kind='messages'",
      );
      expect(count.single['n'], 551);
    },
  );

  test('multi-head pages respect the existing 200-hash RPC limit', () async {
    await connect();
    await sb.synchronize();
    final sender = b.repo as ObservedLanRepository;
    final remote = a.repo as ObservedLanRepository;
    remote.alreadyHasRevisions = true;
    remote.missingBatchSizes.clear();
    sender.manifestFixture = {
      'items': [
        for (var i = 0; i < 100; i++)
          {
            'kind': 'messages',
            'entity_id': 'fixture-$i',
            'hashes': [
              for (var j = 0; j < 3; j++)
                (i * 3 + j).toRadixString(16).padLeft(64, '0'),
            ],
          },
      ],
      'after': 'messages/fixture-99',
      'has_more': false,
    };
    await sb.synchronize();
    expect(sb.peers.peers['a']!.error, isNull);
    expect(remote.missingBatchSizes, [200, 100]);
  });

  test('attachments start while a message receive is still pending', () async {
    await seedLan(a);
    final file = File('${root.path}/wallpaper.bin');
    await file.writeAsBytes(List.generate(1024, (i) => i % 251));
    final record = await a.media.register(
      file.path,
      createdAtMs: 1,
      mimeType: 'image/unsupported',
      originalRequired: true,
    );
    await a.local.execute(
      'UPDATE conversations SET chat_background_image=? WHERE id=?',
      [record.originalPath, 'role'],
    );
    await connect();
    final receiver = b.repo as ObservedLanRepository;
    receiver.holdMessages = true;
    final sync = sb.synchronize();
    try {
      await receiver.messageEntered.future.timeout(const Duration(seconds: 10));
      final destination = File(
        await b.media.originalDestination(record.asset.id),
      );
      expect(
        await eventually(destination.exists),
        true,
        reason:
            'Media must not wait for completion of the entire metadata loop.',
      );
      expect(await destination.readAsBytes(), await file.readAsBytes());
    } finally {
      receiver.resumeMessages.complete();
      await sync;
    }
  });

  test('one media worker drains more than one eight-file batch', () async {
    await connect();
    await sb.synchronize();
    final peer = sb.peers.peers['a']!;
    for (var i = 0; i < 20; i++) {
      final file = File('${root.path}/asset-$i.bin');
      await file.writeAsBytes([i, i + 1, i + 2]);
      final record = await a.media.register(
        file.path,
        createdAtMs: i + 1,
        mimeType: 'audio/wav',
      );
      await sb.media.prepare(peer, [record.asset.id]);
    }
    await sb.synchronize();
    expect(
      await eventually(() async => (await sb.media.counts()).$1 == 0),
      true,
      reason:
          'Successful media batches should continue without another timer tick.',
    );
  });
}
