@Tags(['slow'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show ToolCallScope, GateOutcome;
import 'package:aicove_flutter/src/features/workspace/application/workspace_shell.dart';
import 'package:aicove_flutter/src/features/workspace/data/workspace_store.dart';
import 'package:drift/drift.dart'
    show driftRuntimeOptions, Variable, TableUpdate;
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_crypto.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_discovery.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_media.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_repository.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_service.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_sync_port.dart';
import 'lan_repository_test.dart' show LanTestDevice, lanTestDevice, seedLan;
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/core/sync/cloud_local_write.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_preset_store.dart';
import 'package:aicove_flutter/src/features/agent_context/data/silly_tavern_variable_store.dart';
import 'lan_transport_test.dart' show LanMemoryCredentials;

class LanCountingRepository extends LanRepository {
  LanCountingRepository(LanRepository source)
    : super(source.local, source.codec, source.deviceId);
  int captures = 0, manifests = 0, recentReads = 0, conflictReads = 0;
  int activeConflictReads = 0, maxActiveConflictReads = 0;
  int? manifestPageSize;
  final missingBatches = <List<String>>[];

  @override
  Future<List<String>> missing(Iterable<String> hashes) {
    missingBatches.add(hashes.toList());
    return super.missing(hashes);
  }

  Completer<void>? pauseRecent, recentEntered;
  Completer<void>? pauseLastCapture, lastCaptureEntered;
  int? pauseCaptureNumber;
  int? simulateRecentOverflowOnCapture;
  bool simulateRecentOverflow = false;
  Completer<void>? pauseConflicts, conflictsEntered;
  Object? conflictFailure;
  Completer<void>? pauseReceive, receiveEntered;
  Object? receiveFailure;

  @override
  Future<void> receive(LanRevision incoming) async {
    final gate = pauseReceive;
    if (gate != null) {
      pauseReceive = null;
      receiveEntered?.complete();
      await gate.future;
    }
    final failure = receiveFailure;
    receiveFailure = null;
    if (failure != null) throw failure;
    await super.receive(incoming);
  }

  @override
  Future<List<List<LanRevision>>> conflicts() async {
    conflictReads++;
    activeConflictReads++;
    if (activeConflictReads > maxActiveConflictReads) {
      maxActiveConflictReads = activeConflictReads;
    }
    try {
      final gate = pauseConflicts;
      if (gate != null) {
        pauseConflicts = null;
        conflictsEntered?.complete();
        await gate.future;
      }
      final failure = conflictFailure;
      conflictFailure = null;
      if (failure != null) throw failure;
      return await super.conflicts();
    } finally {
      activeConflictReads--;
    }
  }

  @override
  Future<void> capture({bool scanExternal = true}) async {
    captures++;
    await super.capture(scanExternal: scanExternal);
    if (captures == simulateRecentOverflowOnCapture) {
      simulateRecentOverflow = true;
    }
    if (captures == pauseCaptureNumber) {
      lastCaptureEntered?.complete();
      await pauseLastCapture?.future;
    }
  }

  @override
  Future<Map<String, dynamic>> manifest({String after = '', int limit = 100}) {
    manifests++;
    return super.manifest(after: after, limit: manifestPageSize ?? limit);
  }

  @override
  Future<Map<String, dynamic>> recentChanges() async {
    final gate = pauseRecent;
    if (gate != null) {
      pauseRecent = null;
      recentEntered?.complete();
      await gate.future;
    }
    final result = await super.recentChanges();
    recentReads++;
    if (simulateRecentOverflow) {
      return {
        ...result,
        'revision': 1000,
        'evicted_revision': 500,
        'token': '${result['run']}:1000',
      };
    }
    return result;
  }
}

// Only service-owned expiry/retry tasks are controlled; DB and HTTP stay real.
class LanScheduledTimer implements Timer {
  LanScheduledTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  void fire() {
    expect(isActive, isTrue);
    isActive = false;
    tick++;
    callback();
  }

  @override
  void cancel() => isActive = false;
}

class LanTestDiscovery implements LanDiscovery, LanDiscoveryLifecycle {
  @override
  void Function()? onStopped;
  void lose() {
    active = false;
    onStopped?.call();
  }

  bool active = false;
  @override
  bool get isRunning => active;
  int starts = 0, stops = 0;
  bool failStart = false;
  Completer<void>? startEntered, startRelease;
  void Function(String, List<LanEndpoint>)? found;
  @override
  Future<void> start(
    String id,
    int port,
    void Function(String, List<LanEndpoint>) found,
  ) async {
    await stop();
    starts++;
    if (failStart) throw StateError('Discovery registration failed');
    active = true;
    this.found = found;
    startEntered?.complete();
    await startRelease?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    active = false;
  }
}

void main() {
  test('small and multibyte encrypted payloads round trip', () async {
    final key = await LanCrypto.randomKey();
    for (final value in [
      {
        'revision': {'text': 'small'},
      },
      {'text': '汉' * 6000},
      {'text': '\n' * 8200},
    ]) {
      final envelope = await LanCrypto.seal(
        key,
        value,
        from: 'a',
        to: 'b',
        requestId: 'request',
      );
      expect(
        await LanCrypto.open(
          key,
          envelope,
          from: 'a',
          to: 'b',
          requestId: 'request',
        ),
        value,
      );
    }
  });

  test('large encrypted messages round trip through the isolate', () async {
    final key = await LanCrypto.randomKey();
    final value = {
      'revision': {'text': '大' * 40000},
    };
    final envelope = await LanCrypto.seal(
      key,
      value,
      from: 'a',
      to: 'b',
      requestId: 'request',
    );
    final decoded = await LanCrypto.open(
      key,
      envelope,
      from: 'a',
      to: 'b',
      requestId: 'request',
    );
    expect(decoded, value);
  });

  late Directory root;
  late LanTestDevice a, b;
  late LanService sa, sb;
  late LanTestDiscovery da, db;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('aicove-lan-http-');
    a = await lanTestDevice(root, 'a');
    b = await lanTestDevice(root, 'b');
    da = LanTestDiscovery();
    db = LanTestDiscovery();
    sa = LanService(
      a.repo,
      LanPeerStore(LanMemoryCredentials(), loopback: true),
      discovery: da,
      loopback: true,
      automatic: false,
    );
    sb = LanService(
      b.repo,
      LanPeerStore(LanMemoryCredentials(), loopback: true),
      discovery: db,
      loopback: true,
      automatic: false,
    );
    await sa.initialize();
    await sb.initialize();
    await sa.setEnabled(true);
    await sb.setEnabled(true);
  });
  tearDown(() async {
    await sa.close();
    await sb.close();
    for (final d in [a, b]) {
      await d.media.close();
      await d.local.db.close();
    }
    await root.delete(recursive: true);
  });
  Future<void> pair() async {
    await sa.invite();
    await sb.pair(sa.state.invitation!);
    expect(sb.state.peers.single.pending, true);
    expect(sa.state.peers.single.incoming, true);
    await sa.approve('b');
    await sb.synchronize();
    await sa.synchronize();
    expect(sa.state.error, isNull);
    expect(sb.state.error, isNull);
    expect(sa.peers.peers['b']!.error, isNull);
    expect(sb.peers.peers['a']!.error, isNull);
  }

  Future<List<LanScheduledTimer>> automaticA({bool automaticB = false}) async {
    final aPeers = sa.peers, bPeers = sb.peers;
    await sa.close();
    await sb.close();
    a = LanTestDevice(a.local, a.media, LanCountingRepository(a.repo));
    b = LanTestDevice(b.local, b.media, LanCountingRepository(b.repo));
    final timers = <LanScheduledTimer>[];
    Timer schedule(Duration duration, void Function() callback) {
      final timer = LanScheduledTimer(duration, callback);
      timers.add(timer);
      return timer;
    }

    await runZoned(
      () async {
        sa = LanService(
          a.repo,
          aPeers,
          discovery: da,
          loopback: true,
          scheduleTimer: schedule,
        );
        sb = LanService(
          b.repo,
          bPeers,
          discovery: db,
          loopback: true,
          automatic: automaticB,
          scheduleTimer: schedule,
        );
        await sa.initialize();
        await sb.initialize();
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 3)) {
            fail('LAN must not install its old periodic polling timer');
          }
          return parent.createPeriodicTimer(zone, duration, callback);
        },
      ),
    );
    return timers;
  }

  Future<void> waitFor(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue, reason: 'LAN round did not finish');
    // Let the completion publish finish its database reads as well.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> settle() async {
    await waitFor(() => !sa.state.busy && !sb.state.busy);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await waitFor(() => !sa.state.busy && !sb.state.busy);
  }

  Future<void> referenceAttachments(List<String> ids) async {
    for (var i = 0; i < ids.length; i++) {
      await a.local.execute(
        'INSERT INTO conversations(id,title,display_name,created_at,updated_at,chat_background_image) VALUES(?,?,?,?,?,?)',
        [
          'file-owner-$i',
          'attachment',
          'attachment',
          1,
          1,
          'aicove-media://${ids[i]}',
        ],
      );
    }
  }

  List<LogEntry> roundLogs() => AppLogger.entries.value
      .where((entry) => entry.metadata?['event'] == 'lanRound')
      .toList();

  test(
    'concurrent state refreshes share reads and flush the latest state',
    () async {
      final timers = await automaticA();
      final repo = a.repo as LanCountingRepository;
      final before = repo.conflictReads;
      final gate = Completer<void>();
      final followUpGate = Completer<void>();
      repo.pauseConflicts = gate;
      repo.conflictsEntered = Completer<void>();
      final first = sa.foreground(true);
      try {
        await repo.conflictsEntered!.future;
        final second = sa.foreground(true);
        final third = sa.setName('最新名称');
        await waitFor(
          () => a.local.preferences.getString('aicove.lan.name') == '最新名称',
        );
        expect(repo.conflictReads, before + 1);
        expect(repo.maxActiveConflictReads, 1);
        var completed = 0;
        final pending = Future.wait([
          for (final refresh in [first, second, third])
            refresh.then((_) => completed++),
        ]);
        repo.pauseConflicts = followUpGate;
        repo.conflictsEntered = Completer<void>();
        gate.complete();
        await repo.conflictsEntered!.future;
        await Future<void>.delayed(Duration.zero);
        expect(completed, 0);
        followUpGate.complete();
        await pending;
        expect(repo.conflictReads, before + 2);
        expect(repo.maxActiveConflictReads, 1);
        expect(sa.state.name, '最新名称');
        expect(timers.where((timer) => timer.isActive), isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        if (!followUpGate.isCompleted) followUpGate.complete();
        await first;
      }
    },
  );

  test('a failed state refresh can be retried', () async {
    await automaticA();
    final repo = a.repo as LanCountingRepository;
    repo.conflictFailure = StateError('temporary query failure');
    await expectLater(sa.foreground(true), throwsStateError);
    await sa.setName('重试成功');
    expect(sa.state.name, '重试成功');
    expect(repo.activeConflictReads, 0);
  });

  test(
    'idle unpaired service has no scheduled tasks or database reads',
    () async {
      final timers = await automaticA();
      await settle();
      final repo = a.repo as LanCountingRepository;
      final before = repo.conflictReads;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(repo.conflictReads, before);
      expect(repo.recentReads, 0);
    },
  );

  test(
    'media counts aggregate strict booleans and reject invalid objects',
    () async {
      expect(await sa.media.counts(), (0, 0));
      final documents = [
        '{}',
        '{"unavailable":true}',
        '{"unavailable":false}',
        '{"unavailable":null}',
        '{"unavailable":1}',
        '{"unavailable":1.0}',
        '{"unavailable":"true"}',
      ];
      for (var i = 0; i < documents.length; i++) {
        await a.local.execute(
          'INSERT INTO lan_media_queue(media_id,peer_id,asset_json) VALUES(?,?,?)',
          ['media$i', 'peer', documents[i]],
        );
      }
      expect(await sa.media.counts(), (6, 1));
      for (final invalid in ['[]', 'null', 'true', '1', '"text"', '{broken']) {
        await a.local.execute(
          'INSERT OR REPLACE INTO lan_media_queue(media_id,peer_id,asset_json) VALUES(?,?,?)',
          ['invalid', 'peer', invalid],
        );
        await expectLater(sa.media.counts(), throwsA(anything));
      }
      await a.local.execute('DELETE FROM lan_media_queue');
      expect(await sa.media.counts(), (0, 0));
    },
  );

  test('repeated automatic foreground does not resubscribe or scan', () async {
    final timers = await automaticA();
    await pair();
    await settle();
    final captures = (a.repo as LanCountingRepository).captures;
    final manifests = (b.repo as LanCountingRepository).manifests;
    final logs = roundLogs().length, starts = da.starts;
    await sa.foreground(true);
    await sa.foreground(true);
    await settle();
    expect(timers.where((t) => t.isActive), isEmpty);
    expect(da.starts, starts);
    expect((a.repo as LanCountingRepository).captures, captures);
    expect((b.repo as LanCountingRepository).manifests, manifests);
    expect(roundLogs().length, logs);
  });

  test(
    'unpaired and incoming-unapproved service stays quiet without events',
    () async {
      final timers = await automaticA();
      for (final pending in [false, true]) {
        if (pending) {
          await sa.invite();
          await sb.pair(sa.state.invitation!);
          expect(sa.peers.peers['b']!.approved, isFalse);
        }
        await settle();
        final events = <LanSyncState>[];
        final subscription = sa.changes.listen(events.add);
        final logs = roundLogs().length;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(roundLogs().length, logs);
        expect(events, isEmpty);
        expect((a.repo as LanCountingRepository).captures, 0);
        expect(timers.where((t) => t.isActive), isEmpty);
        await subscription.cancel();
      }
    },
  );

  test(
    'approved idle stays silent past sixty seconds; manual sync still scans',
    () async {
      final timers = await automaticA();
      await pair();
      await settle();
      final repo = a.repo as LanCountingRepository;
      final remote = b.repo as LanCountingRepository;
      final captures = repo.captures, manifests = remote.manifests;
      final reads = repo.recentReads, remoteReads = remote.recentReads;
      final conflictReads = repo.conflictReads;
      final logs = roundLogs().length;
      sa.peers.peers['b']!.lastSync = DateTime.now().subtract(
        const Duration(seconds: 61),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(repo.captures, captures);
      expect(remote.manifests, manifests);
      expect(repo.recentReads, reads);
      expect(remote.recentReads, remoteReads);
      expect(repo.conflictReads, conflictReads);
      expect(roundLogs().length, logs);
      final events = <LanSyncState>[];
      final subscription = sa.changes.listen(events.add);
      addTearDown(subscription.cancel);
      await sa.synchronize();
      expect(repo.captures, captures + 2);
      expect(
        events.any(
          (state) =>
              state.progressLabel == '正在整理本机修改' && state.progress != null,
        ),
        isTrue,
      );
      expect(sa.state.progressLabel, isNull);
    },
  );

  test(
    'full manifest pagination polls recent at most every ten quiet pages',
    () async {
      await seedLan(a);
      for (var i = 0; i < 24; i++) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
          ['page-$i', 'role', 'assistant', 'page', i + 2],
        );
      }
      await automaticA();
      await pair();
      await settle();
      final local = a.repo as LanCountingRepository;
      final remote = b.repo as LanCountingRepository;
      local.manifestPageSize = 1;
      remote.manifestPageSize = 1;
      final localReads = local.recentReads, remoteReads = remote.recentReads;
      final localPages = local.manifests, remotePages = remote.manifests;
      await sa.synchronize();
      expect(local.manifests - localPages, greaterThanOrEqualTo(25));
      expect(remote.manifests - remotePages, greaterThanOrEqualTo(25));
      expect(local.recentReads - localReads, lessThanOrEqualTo(8));
      expect(remote.recentReads - remoteReads, lessThanOrEqualTo(4));
    },
  );

  test('manifest filters an entire page with one missing lookup', () async {
    await automaticA();
    await seedLan(a);
    await pair();
    await sa.synchronize();
    final repo = a.repo as LanCountingRepository;
    final remote = b.repo as LanCountingRepository;
    repo.missingBatches.clear();
    remote.manifestPageSize = 2;
    final pages = remote.manifests;
    await sa.synchronize();
    expect(remote.manifests - pages, greaterThan(1));
    expect(repo.missingBatches.length, remote.manifests - pages);
    expect(repo.missingBatches.any((batch) => batch.length > 1), isTrue);
    for (final batch in repo.missingBatches) {
      expect(batch.length, batch.toSet().length);
    }
  });

  test('recent pulls do not recheck missing hashes per item', () async {
    await automaticA();
    await seedLan(a);
    await pair();
    await sa.synchronize();
    final repo = a.repo as LanCountingRepository;
    final remote = b.repo as LanCountingRepository;
    await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
      'recent edit',
      'message',
    ]);
    repo.missingBatches.clear();
    final pages = remote.manifests;
    await sa.synchronize();
    expect(repo.missingBatches.length, remote.manifests - pages + 1);
    expect(
      (await a.local.read('messages', 'message'))!.payload['row']['content'],
      'recent edit',
    );
  });

  test(
    'approval propagates automatically through authenticated status',
    () async {
      final timers = await automaticA(automaticB: true);
      await seedLan(b);
      await sb.invite();
      await sa.pair(sb.state.invitation!);
      expect(sa.peers.peers['b']!.approved, isFalse);
      await settle();
      expect((a.repo as LanCountingRepository).captures, 0);
      expect(timers.where((t) => t.isActive), hasLength(1));
      await sb.approve('a');
      await waitFor(() => sa.peers.peers['b']!.approved);
      await settle();
      expect(
        (await a.local.read('messages', 'message'))!.payload['row']['content'],
        '原文',
      );
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'committed edits and discovery recovery trigger complete rounds',
    () async {
      await automaticA();
      await seedLan(a);
      await pair();
      await settle();
      await a.local.db.customUpdate(
        'UPDATE messages SET content=? WHERE id=?',
        variables: const [Variable('committed edit'), Variable('message')],
        updates: {a.local.db.messages},
      );
      await waitFor(
        () => !sa.state.busy && (a.repo as LanCountingRepository).captures > 0,
      );
      await settle();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'committed edit',
      );
      await sb.foreground(false);
      await sa.synchronize();
      expect(sa.peers.peers['b']!.online, isFalse);
      await sb.foreground(true);
      da.found!('b', [LanEndpoint('127.0.0.1', sb.transport.port)]);
      await waitFor(() => sa.peers.peers['b']!.online);
      await settle();
      expect(sa.peers.peers['b']!.error, isNull);
    },
  );

  test(
    'received data does not echo but explicit reconciliation stays complete',
    () async {
      await automaticA();
      await seedLan(a);
      await pair();
      await settle();
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'already shared',
        'message',
      ]);
      await b.repo.capture();
      final page = await b.repo.recentChanges();
      for (final item in page['items'] as List) {
        for (final hash in await a.repo.missing(
          (item['hashes'] as List).cast<String>(),
        )) {
          await a.repo.receive(await b.repo.revision(hash));
        }
      }
      final captures = (a.repo as LanCountingRepository).captures;
      final logs = roundLogs().length;
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
      expect(roundLogs().length, logs);
      await sa.synchronize();
      expect((a.repo as LanCountingRepository).captures, captures + 2);
      expect(roundLogs().last.metadata, containsPair('pushed', 0));
      expect(roundLogs().last.metadata, containsPair('pulled', 0));
      expect(roundLogs().last.metadata, containsPair('failed', 0));
    },
  );

  test('new synchronization requests merge into one follow-up round', () async {
    await automaticA();
    await pair();
    await settle();
    final repo = a.repo as LanCountingRepository;
    final gate = repo.pauseRecent = Completer<void>();
    final entered = repo.recentEntered = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final captures = repo.captures;
    final first = sa.synchronize();
    await entered.future.timeout(const Duration(seconds: 5));
    final second = sa.synchronize();
    final third = sa.synchronize();
    gate.complete();
    await Future.wait([first, second, third]);
    expect(repo.captures, captures + 4);
  });

  test(
    'pending attachments retry without scanning metadata manifests',
    () async {
      final timers = await automaticA();
      await pair();
      await settle();
      final file = File('${root.path}/pending.bin')
        ..writeAsBytesSync([1, 3, 5, 7]);
      final record = await b.media.register(
        file.path,
        createdAtMs: 1,
        mimeType: 'audio/wav',
        originalRequired: true,
      );
      await referenceAttachments([record.asset.id]);
      // File-only retries still have an active settings owner.
      await a.local.preferences.setString(
        'aicove.plugins.media_test',
        jsonEncode({'audioUrl': record.asset.reference}),
      );
      await sa.media.prepare(sa.peers.peers['b']!, [record.asset.id]);
      final destination = File(
        await a.media.originalDestination(record.asset.id),
      );
      // Publishing the queue state arms a file-only retry.
      await sa.foreground(true);
      final captures = (a.repo as LanCountingRepository).captures;
      final manifests = (b.repo as LanCountingRepository).manifests;
      timers.singleWhere((t) => t.isActive).fire();
      await waitFor(destination.existsSync);
      await settle();
      expect(destination.readAsBytesSync(), [1, 3, 5, 7]);
      expect(await a.local.rows('SELECT * FROM lan_media_queue'), isEmpty);
      expect((a.repo as LanCountingRepository).captures, captures);
      expect((b.repo as LanCountingRepository).manifests, manifests);
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'unavailable attachments stop retrying and resume on the next real wake',
    () async {
      final timers = await automaticA();
      await pair();
      await settle();
      final file = File('${root.path}/unavailable.bin')
        ..writeAsBytesSync([9, 8, 7]);
      final record = await b.media.register(
        file.path,
        createdAtMs: 1,
        mimeType: 'audio/wav',
        originalRequired: true,
      );
      await referenceAttachments([record.asset.id]);
      await sa.media.prepare(sa.peers.peers['b']!, [record.asset.id]);
      await File(record.originalPath!).delete();
      await sa.foreground(true);
      timers.singleWhere((t) => t.isActive).fire();
      await waitFor(() => sa.state.unavailableFiles == 1);
      await settle();
      expect(sa.state.pendingFiles, 0);
      expect(timers.where((t) => t.isActive), isEmpty);
      await File(record.originalPath!).writeAsBytes([9, 8, 7]);
      await sa.synchronize();
      await settle();
      expect(await sa.media.counts(), (0, 0));
      expect(
        await File(
          await a.media.originalDestination(record.asset.id),
        ).readAsBytes(),
        [9, 8, 7],
      );
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'attachment batches refresh counts without clearing metadata work',
    () async {
      await automaticA();
      await pair();
      await sa.synchronize();
      await settle();
      final repo = a.repo as LanCountingRepository;
      final ids = <String>[];
      for (var i = 0; i < 10; i++) {
        final file = File(
          '${root.path}/attachment$i.bin',
        )..writeAsBytesSync(List<int>.filled(i == 0 ? lanChunkSize * 3 : 8, i));
        final record = await b.media.register(
          file.path,
          createdAtMs: i,
          mimeType: 'audio/wav',
          originalRequired: true,
        );
        ids.add(record.asset.id);
      }
      await referenceAttachments(ids);
      await a.local.preferences.setString(
        'aicove.plugins.media_test',
        jsonEncode({'images': ids.map((id) => 'aicove-media://$id').toList()}),
      );
      await sa.media.prepare(sa.peers.peers['b']!, ids);
      final events = <LanSyncState>[];
      final subscription = sa.changes.listen(events.add);
      addTearDown(subscription.cancel);
      final gate = repo.pauseRecent = Completer<void>();
      repo.recentEntered = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final syncing = sa.synchronize();
      await repo.recentEntered!.future;
      await waitFor(() => events.any((state) => state.pendingFiles == 0));
      expect(
        events.any(
          (state) => state.pendingFiles > 0 && state.pendingFiles < 10,
        ),
        isTrue,
      );
      expect(
        events.any((state) => state.progressLabel?.contains('附件') == true),
        isTrue,
      );
      expect(sa.state.busy, isTrue, reason: 'metadata is still waiting');
      expect(sa.state.progressLabel, isNotNull);
      gate.complete();
      await syncing;
      await waitFor(() => !sa.state.busy);
      expect(sa.state.progress, isNull);
      expect(sa.state.progressLabel, isNull);
      expect(await sa.media.counts(), (0, 0));
      for (final state in events.where((state) => state.progress != null)) {
        expect(state.progress, inInclusiveRange(0, 1));
      }
    },
  );

  test(
    'incoming pushes publish receiving and clear progress after failure',
    () async {
      await automaticA();
      await seedLan(a);
      await pair();
      await sa.synchronize();
      final repo = b.repo as LanCountingRepository;
      final page = await a.repo.manifest();
      final item = (page['items'] as List).firstWhere(
        (item) => item['kind'] == 'messages',
      );
      final revision = await a.repo.revision(
        (item['hashes'] as List).first as String,
      );
      for (final fail in [false, true]) {
        final gate = repo.pauseReceive = Completer<void>();
        repo.receiveEntered = Completer<void>();
        if (fail) {
          repo.receiveFailure = const LanSyncFailure('test receive failure');
        }
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final push = sa.transport.rpc(sa.peers.peers['b']!, {
          'method': 'put',
          'revision': revision.toJson(),
        });
        // Install failure handling before the real HTTP request can finish.
        final completed = fail
            ? expectLater(push, throwsA(isA<LanSyncFailure>()))
            : push;
        await repo.receiveEntered!.future;
        await waitFor(() => sb.state.busy);
        expect(sb.state.progressLabel, '正在接收聊天与设置');
        expect(sb.state.progress, isNull);
        Future<void>? metadataRound;
        Completer<void>? metadataGate;
        if (!fail) {
          // A second completed push must not hide the first blocked receiver.
          await sa.transport.rpc(sa.peers.peers['b']!, {
            'method': 'put',
            'revision': revision.toJson(),
          });
          expect(sb.state.busy, isTrue);
          metadataGate = repo.pauseRecent = Completer<void>();
          repo.recentEntered = Completer<void>();
          addTearDown(() {
            if (!metadataGate!.isCompleted) metadataGate.complete();
          });
          metadataRound = sb.synchronize();
          await repo.recentEntered!.future;
        }
        gate.complete();
        await completed;
        if (metadataRound != null) {
          await waitFor(() => sb.state.progressLabel == '正在核对同步内容');
          expect(sb.state.busy, isTrue, reason: 'metadata is still waiting');
          metadataGate!.complete();
          await metadataRound;
        }
        await waitFor(() => !sb.state.busy);
        expect(sb.state.progressLabel, isNull);
        expect(sb.state.progress, isNull);
      }
      await sb.close();
      expect(sb.state.busy, isFalse);
      expect(sb.state.progressLabel, isNull);
    },
  );

  test(
    'media chunk progress is current-file scoped and finishes each queue entry',
    () async {
      await pair();
      final file = File('${root.path}/chunk-progress.bin')
        ..writeAsBytesSync(
          List<int>.generate(lanChunkSize * 2 + 7, (i) => i % 251),
        );
      final record = await a.media.register(
        file.path,
        createdAtMs: 1,
        mimeType: 'audio/wav',
        originalRequired: true,
      );
      await sb.media.prepare(sb.peers.peers['a']!, [record.asset.id]);
      final samples = <(double?, String, int)>[];
      await sb.media.drain(
        sb.peers.peers,
        () => true,
        onProgress: (progress, label) async {
          samples.add((progress, label, (await sb.media.counts()).$1));
        },
      );
      expect(
        samples.any(
          (sample) =>
              sample.$1 != null &&
              sample.$1! > 0 &&
              sample.$1! < 1 &&
              sample.$2.contains('正在接收附件'),
        ),
        isTrue,
      );
      expect(samples.last.$3, 0);
      expect(samples.last.$1, 1);
    },
  );

  test('shell structured output uses the same bounded model tail', () async {
    final directory = Directory('${root.path}/shell-output')..createSync();
    final store = await WorkspaceStore.open(directory);
    try {
      final workspace = (await store.create(name: 'output regression')).id;
      final scope = ToolCallScope()
        ..outcome = GateOutcome.approved
        ..humanApproved = true;
      final result = await scope.run(
        () => WorkspaceShell(
          store: store,
          workspace: workspace,
          runId: 'output',
        ).run("head -c 8388609 /dev/zero | tr '\\000' x"),
      );
      expect(result.isError, isFalse, reason: result.text);
      final structured = result.structured! as Map<String, dynamic>;
      expect(structured['truncated'], isTrue);
      expect(
        utf8.encode(structured['output'] as String).length,
        lessThanOrEqualTo(50 * 1024),
      );
      expect(structured['output'], isNot(contains('full output:')));
      final path = structured['full_output_path'] as String;
      expect(
        await File('${store.directoryOf(workspace).path}/$path').length(),
        8 * 1024 * 1024,
      );
    } finally {
      await store.close();
    }
  });

  test(
    'invitations expire once and consumed invitations cancel their timer',
    () async {
      final timers = await automaticA();
      await sa.invite();
      final old = timers.singleWhere((t) => t.isActive);
      expect(old.duration, greaterThan(const Duration(minutes: 9)));
      await sa.invite();
      expect(old.isActive, isFalse);
      final current = sa.state.invitation;
      old.callback();
      expect(sa.transport.invitation!.code, current);
      timers.singleWhere((t) => t.isActive).fire();
      await waitFor(() => sa.state.invitation == null && sa.state.pin == null);
      expect(sa.transport.invitation, isNull);
      final reads = (a.repo as LanCountingRepository).conflictReads;
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect((a.repo as LanCountingRepository).conflictReads, reads);
      expect(timers.where((t) => t.isActive), isEmpty);
      await sa.invite();
      await sb.pair(sa.state.invitation!);
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'background cancels tasks and DB wakes; resume alone synchronizes',
    () async {
      final timers = await automaticA();
      await seedLan(a);
      await pair();
      await settle();
      await sa.foreground(false);
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(sa.transport.listening, isFalse);
      expect(da.isRunning, isFalse);
      final logs = roundLogs().length;
      await a.local.db.customUpdate(
        'UPDATE messages SET content=? WHERE id=?',
        variables: const [Variable('background edit'), Variable('message')],
        updates: {a.local.db.messages},
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(roundLogs().length, logs);
      await sa.foreground(true);
      await settle();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'background edit',
      );
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test('repeated foreground preserves the running discovery', () async {
    final starts = da.starts, stops = da.stops;
    final port = sa.transport.port;
    await sa.foreground(true);
    await sa.foreground(true);
    await sa.setEnabled(true);
    expect(da.starts, starts);
    expect(da.stops, stops);
    expect(sa.transport.port, port);
    expect(da.active, isTrue);
  });

  test('foreground rebuilds discovery after the listener is lost', () async {
    final starts = da.starts, stops = da.stops;
    await sa.transport.stop();
    await sa.foreground(true);
    expect(sa.transport.listening, isTrue);
    expect(da.starts, starts + 1);
    expect(da.stops, stops + 1);
    expect(da.active, isTrue);
  });

  test('foreground restarts discovery if the platform stopped it', () async {
    final starts = da.starts;
    da.active = false;
    await sa.foreground(true);
    expect(da.starts, starts + 1);
    expect(da.active, isTrue);
  });

  test('background and disable release discovery and allow restart', () async {
    final starts = da.starts;
    await sa.foreground(false);
    expect(da.active, isFalse);
    expect(sa.transport.listening, isFalse);
    await sa.foreground(true);
    expect(da.starts, starts + 1);
    await sa.setEnabled(false);
    expect(da.active, isFalse);
    await sa.setEnabled(true);
    expect(da.starts, starts + 2);
  });

  test('failed discovery is retried on the next foreground', () async {
    await sa.foreground(false);
    da.failStart = true;
    await sa.foreground(true);
    expect(sa.state.notice, contains('自动发现暂不可用'));
    expect(sa.transport.listening, isTrue);
    da.failStart = false;
    await sa.foreground(true);
    expect(da.active, isTrue);
    expect(sa.state.notice, isNot(contains('自动发现暂不可用')));
  });

  test(
    'a failed pre-receive backup is retried instead of rejecting every push',
    () async {
      await seedLan(a);
      // A file where the backup directory belongs makes the first backup fail.
      final blocker = File('${root.path}/b/support/cloud_backups')
        ..writeAsStringSync('');
      await sa.invite();
      await sb.pair(sa.state.invitation!);
      await sa.approve('b');
      await sb.synchronize();
      await sa.synchronize();
      expect(await b.local.read('messages', 'message'), isNull);

      blocker.deleteSync();
      await sb.synchronize();
      expect(sb.peers.peers['a']!.error, isNull);
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '原文',
      );
    },
  );

  test(
    'six-digit code pairs a nearby device through an X25519 exchange',
    () async {
      await seedLan(a);
      await sa.invite();
      final pin = sa.state.pin!;
      expect(pin, matches(RegExp(r'^\d{6}$')));
      db.found!('a', [LanEndpoint('127.0.0.1', sa.transport.port)]);
      await sb.pair('${pin.substring(0, 3)} ${pin.substring(3)}');
      expect(sb.state.error, isNull);
      expect(sb.state.peers.single.name, sa.state.name);
      expect(sb.state.peers.single.pending, true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sa.state.peers.single.incoming, true);
      expect(sa.state.pin, isNull);
      final key = sb.peers.peers['a']!.key;
      expect(sa.peers.peers['b']!.key, key);
      expect(
        key,
        isNot(await LanCrypto.pinKey(pin, 'a')),
        reason: 'the pair key must not be derivable from the short code alone',
      );
      await sa.approve('b');
      await sb.synchronize();
      expect(sb.peers.peers['a']!.error, isNull);
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '原文',
      );
    },
  );
  test('wrong six-digit codes burn the code after five attempts', () async {
    await sa.invite();
    final pin = sa.state.pin!;
    final wrong = ((int.parse(pin) + 1) % 1000000).toString().padLeft(6, '0');
    db.found!('a', [LanEndpoint('127.0.0.1', sa.transport.port)]);
    for (var i = 0; i < lanPinAttempts; i++) {
      await sb.pair(wrong);
      expect(sb.state.error, contains('数字配对码不正确'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(sa.state.pin, isNull);
    await sb.pair(pin);
    expect(sb.state.error, contains('附近没有找到'));
    expect(sb.state.peers, isEmpty);
    expect(sa.state.peers, isEmpty);
    // The QR code stays usable; only the guessable code is closed.
    await sb.pair(sa.state.invitation!);
    expect(sb.state.error, isNull);
  });
  test(
    'image pairing decodes a complete invitation without camera or network',
    () async {
      await sa.invite();
      final code = sa.state.invitation!;
      final matrix = Encoder.encode(code, ErrorCorrectionLevel.m).matrix!;
      const scale = 6, quiet = 4;
      final image = img.Image(
        width: (matrix.width + quiet * 2) * scale,
        height: (matrix.height + quiet * 2) * scale,
      );
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      for (var y = 0; y < matrix.height; y++) {
        for (var x = 0; x < matrix.width; x++) {
          if (matrix.get(x, y) != 1) continue;
          img.fillRect(
            image,
            x1: (x + quiet) * scale,
            y1: (y + quiet) * scale,
            x2: (x + quiet + 1) * scale - 1,
            y2: (y + quiet + 1) * scale - 1,
            color: img.ColorRgb8(0, 0, 0),
          );
        }
      }
      expect(await sb.decodeQr(img.encodePng(image)), code);
    },
  );
  test(
    'private LAN interface accepts authenticated transfer without a cloud endpoint',
    () async {
      final hostStore = LanPeerStore(LanMemoryCredentials());
      final guestStore = LanPeerStore(LanMemoryCredentials());
      final host = LanTransport(
        'host',
        hostStore,
        (peer, body) async => {'text': '局域网原文'},
        () {},
      );
      final guest = LanTransport(
        'guest',
        guestStore,
        (peer, body) async => {'ok': true},
        () {},
      );
      await host.start();
      await guest.start();
      addTearDown(() async {
        await host.stop();
        await guest.stop();
      });
      final endpoints = await host.addresses();
      if (endpoints.isEmpty) {
        markTestSkipped('Host has no IPv4 LAN interface');
        return;
      }
      await guest.pair(await host.invite('电脑'), '手机');
      hostStore.peers['guest']!.approved = true;
      await hostStore.save();
      expect(
        (await guest.rpc(guestStore.peers['host']!, {
          'method': 'data',
        }))['text'],
        '局域网原文',
      );
    },
  );
  test(
    'six-digit code finds the host by subnet sweep when Bonjour is silent',
    () async {
      final hostStore = LanPeerStore(LanMemoryCredentials());
      final guestStore = LanPeerStore(LanMemoryCredentials());
      final host = LanTransport('host', hostStore, (p, b) async => {}, () {});
      final guest = LanTransport(
        'guest',
        guestStore,
        (p, b) async => {},
        () {},
      );
      await host.start();
      await guest.start();
      addTearDown(() async {
        await host.stop();
        await guest.stop();
      });
      if ((await host.addresses()).isEmpty || host.port != lanPreferredPort) {
        markTestSkipped('No IPv4 LAN interface or the fixed port is taken');
        return;
      }
      await host.invite('电脑');
      await guest.pairPin(host.invitation!.pin!, '手机', const []);
      expect(guestStore.peers['host']!.name, '电脑');
      expect(hostStore.peers['guest']!.key, guestStore.peers['host']!.key);
    },
  );
  test(
    'a request after the last capture is not swallowed by active work',
    () async {
      await automaticA();
      await seedLan(a);
      await pair();
      await sa.foreground(false);
      // Keep this regression independent of the database wake-up timer.
      await sa.close();
      sa = LanService(
        a.repo,
        sa.peers,
        discovery: da,
        loopback: true,
        automatic: false,
      );
      await sa.initialize();
      final repo = a.repo as LanCountingRepository;
      repo.pauseCaptureNumber = repo.captures + 2;
      final gate = repo.pauseLastCapture = Completer<void>();
      final entered = repo.lastCaptureEntered = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final first = sa.synchronize();
      await entered.future.timeout(const Duration(seconds: 5));
      await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'late edit',
        'message',
      ]);
      final second = sa.synchronize();
      gate.complete();
      await Future.wait([first, second]);
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'late edit',
      );
    },
  );

  test('one synchronization round drains more than one 500-row batch', () async {
    await pair();
    await a.local.db.transaction(() async {
      for (var i = 0; i < 1100; i++) {
        await a.local.execute(
          'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
          ['bulk-$i', 'role', 'role', 1, 1],
        );
      }
    });
    await sa.synchronize();
    expect(await a.local.rows('SELECT 1 FROM lan_dirty'), isEmpty);
    expect(
      (await b.local.rows(
        'SELECT COUNT(*) AS n FROM conversations',
      )).single['n'],
      greaterThanOrEqualTo(1100),
    );
  });

  test(
    'local preferences wake sync, including removal, but unchanged values do not',
    () async {
      final timers = await automaticA();
      await pair();
      await settle();
      await saveCloudPreference(
        a.local.preferences,
        'direct.model',
        'event-model',
      );
      await settle();
      expect(b.local.preferences.getString('direct.model'), 'event-model');
      final captures = (a.repo as LanCountingRepository).captures;
      await saveCloudPreference(
        a.local.preferences,
        'direct.model',
        'event-model',
      );
      await saveCloudPreference(a.local.preferences, 'not.synced', 'local');
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
      await saveCloudPreference(a.local.preferences, 'direct.model', null);
      await settle();
      expect(b.local.preferences.get('direct.model'), isNull);
      await sa.setName('新设备名');
      await settle();
      expect(sb.peers.peers['a']!.name, '新设备名');
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'remote preference apply does not emit a local external-change event',
    () async {
      await saveCloudPreference(
        a.local.preferences,
        'direct.model',
        'remote-model',
      );
      await a.repo.capture();
      final page = await a.repo.manifest();
      final item = (page['items'] as List).firstWhere(
        (item) =>
            item['kind'] == 'settings' &&
            item['entity_id'] == cloudObjectId('preference:direct.model'),
      );
      final revision = await a.repo.revision(
        (item['hashes'] as List).single as String,
      );
      final events = <String?>[];
      final subscription = externalSyncChanges.listen(events.add);
      addTearDown(subscription.cancel);
      await b.repo.receive(revision);
      await Future<void>.delayed(Duration.zero);
      expect(b.local.preferences.getString('direct.model'), 'remote-model');
      expect(events, isEmpty);
    },
  );

  test(
    'preset publication, edits, variables and deletion wake synchronization',
    () async {
      await automaticA();
      await pair();
      await settle();
      final store = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => a.local.documents,
      );
      final remote = SillyTavernPresetStore(
        documentsDirectoryResolver: () async => b.local.documents,
      );
      final preset = await store.importSource(
        jsonEncode({
          'name': 'Event preset',
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': 'hello'},
          ],
          'prompt_order': [
            {
              'order': [
                {'identifier': 'main', 'enabled': true},
              ],
            },
          ],
        }),
        sourceFileName: 'event.json',
      );
      await settle();
      expect((await remote.get(preset.id))!.name, 'Event preset');
      await store.setRegexAuthorization(preset.id, true);
      await settle();
      expect((await remote.get(preset.id))!.regexAuthorized, isTrue);
      final variables = SillyTavernVariableStore(
        documentsDirectoryResolver: () async => a.local.documents,
      );
      final remoteVariables = SillyTavernVariableStore(
        documentsDirectoryResolver: () async => b.local.documents,
      );
      await variables.saveIfChanged(
        presetId: preset.id,
        conversationId: 'role',
        previousValues: {},
        values: {'score': '7'},
      );
      await settle();
      expect(
        (await remoteVariables.load(
          presetId: preset.id,
          conversationId: 'role',
        )).values,
        {'score': '7'},
      );
      final captures = (a.repo as LanCountingRepository).captures;
      await variables.saveIfChanged(
        presetId: preset.id,
        conversationId: 'role',
        previousValues: {'score': '7'},
        values: {'score': '7'},
      );
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
      await store.deletePreset(preset.id);
      await settle();
      expect(await remote.get(preset.id), isNull);
    },
  );

  test(
    'sending-only and unrelated table notifications do not start rounds',
    () async {
      await automaticA();
      await seedLan(a);
      await pair();
      await settle();
      final captures = (a.repo as LanCountingRepository).captures;
      await a.local.db.customUpdate(
        'UPDATE messages SET status=? WHERE id=?',
        variables: const [Variable('sending'), Variable('message')],
        updates: {a.local.db.messages},
      );
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
      // No SQL mutation is needed to exercise the subscription filter.
      a.local.db.notifyUpdates({const TableUpdate('cloud_dirty')});
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
      await a.local.db.customUpdate(
        'UPDATE messages SET status=?,content=? WHERE id=?',
        variables: const [
          Variable('sent'),
          Variable('terminal'),
          Variable('message'),
        ],
        updates: {a.local.db.messages},
      );
      await settle();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'terminal',
      );
    },
  );

  test(
    'authenticated requests cannot approve an incoming pending peer',
    () async {
      await automaticA();
      await sa.invite();
      await sb.pair(sa.state.invitation!);
      final peer = sb.peers.peers['a']!..approved = true;
      await sb.transport.rpc(peer, {
        'method': 'status',
        'approved': true,
        'name': 'guest',
        'endpoints': (await sb.transport.addresses())
            .map((e) => e.toJson())
            .toList(),
      });
      await sa.synchronize();
      expect(sa.peers.peers['b']!.incoming, isTrue);
      expect(sa.peers.peers['b']!.approved, isFalse);
      expect((a.repo as LanCountingRepository).captures, 0);
    },
  );

  test(
    'approval requires a valid authenticated status and true declaration',
    () async {
      await automaticA();
      await sb.invite();
      await sa.pair(sb.state.invitation!);
      final peer = sb.peers.peers['a']!..approved = true;
      await expectLater(
        sb.transport.rpc(peer, {
          'method': 'status',
          'approved': true,
          'name': 'host',
          'endpoints': [],
        }),
        throwsA(isA<LanSyncFailure>()),
      );
      expect(sa.peers.peers['b']!.approved, isFalse);
      await sb.transport.rpc(peer, {
        'method': 'status',
        'approved': false,
        'name': 'host',
        'endpoints': (await sb.transport.addresses())
            .map((e) => e.toJson())
            .toList(),
      });
      expect(sa.peers.peers['b']!.approved, isFalse);
    },
  );

  test(
    'an authenticated offline-to-online transition wakes once, not every RPC',
    () async {
      await automaticA();
      await pair();
      await settle();
      final repo = a.repo as LanCountingRepository;
      final before = repo.captures;
      sa.peers.peers['b']!.online = false;
      final status = {
        'method': 'status',
        'approved': true,
        'name': 'guest',
        'endpoints': (await sb.transport.addresses())
            .map((e) => e.toJson())
            .toList(),
      };
      await sb.transport.rpc(sb.peers.peers['a']!, status);
      await settle();
      expect(sa.peers.peers['b']!.online, isTrue);
      expect(repo.captures, greaterThan(before));
      final after = repo.captures;
      await sb.transport.rpc(sb.peers.peers['a']!, status);
      await settle();
      expect(repo.captures, after);
    },
  );

  test(
    'pending approval probes stop after their finite retry budget',
    () async {
      final timers = await automaticA();
      await sb.invite();
      await sa.pair(sb.state.invitation!);
      final expectedDelays = [1, 3, 10, 30];
      for (var i = 0; i < expectedDelays.length; i++) {
        final timer = timers.singleWhere((t) => t.isActive);
        expect(timer.duration, Duration(seconds: expectedDelays[i]));
        final count = timers.length;
        timer.fire();
        if (i < expectedDelays.length - 1) {
          await waitFor(() => timers.length > count);
        } else {
          await settle();
        }
      }
      expect(timers.where((t) => t.isActive), isEmpty);
      expect(sa.peers.peers['b']!.approved, isFalse);
      expect((a.repo as LanCountingRepository).captures, 0);
    },
  );

  test(
    'failed metadata rounds retry finitely and cancellation stops the task',
    () async {
      final timers = await automaticA();
      await pair();
      await settle();
      await sb.foreground(false);
      await sa.synchronize();
      for (var i = 0; i < 4; i++) {
        final logs = roundLogs().length;
        timers.singleWhere((t) => t.isActive).fire();
        await waitFor(() => roundLogs().length > logs);
        await settle();
      }
      expect(timers.where((t) => t.isActive), isEmpty);
      await sa.synchronize();
      expect(timers.where((t) => t.isActive), hasLength(1));
      await sa.forget('b');
      expect(timers.where((t) => t.isActive), isEmpty);
      await sa.invite();
      expect(timers.where((t) => t.isActive), hasLength(1));
      await sa.foreground(false);
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'listener loss signals and discovery loss recover without periodic checks',
    () async {
      final timers = await automaticA();
      final starts = da.starts;
      await sa.transport.stop();
      // Deliver the same signal as HttpServer.onDone, after its listener is gone.
      sa.transport.changed();
      await waitFor(() => sa.transport.listening && da.starts > starts);
      da.lose();
      await waitFor(() => da.isRunning && da.starts > starts + 1);
      expect(timers.where((t) => t.isActive), isEmpty);
      await sa.setEnabled(false);
      final stoppedAt = da.starts;
      sa.transport.changed();
      da.onStopped?.call();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(da.starts, stoppedAt);
      expect(sa.transport.listening, isFalse);
    },
  );

  test(
    'a second discovery loss during recovery is retained and retried',
    () async {
      final timers = await automaticA();
      final starts = da.starts;
      final entered = da.startEntered = Completer<void>();
      final release = da.startRelease = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      da.lose();
      await entered.future;
      da.lose();
      da.startEntered = da.startRelease = null;
      release.complete();
      await waitFor(
        () => da.starts == starts + 1 && timers.any((t) => t.isActive),
      );
      expect(da.isRunning, isFalse);
      timers.singleWhere((t) => t.isActive).fire();
      await waitFor(() => da.isRunning && da.starts == starts + 2);
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );

  test(
    'new incoming revisions relay to another peer once and then settle',
    () async {
      await automaticA();
      await seedLan(b);
      await pair();
      final c = await lanTestDevice(root, 'c');
      final sc = LanService(
        c.repo,
        LanPeerStore(LanMemoryCredentials(), loopback: true),
        discovery: LanTestDiscovery(),
        loopback: true,
        automatic: false,
      );
      addTearDown(() async {
        await sc.close();
        await c.media.close();
        await c.local.db.close();
      });
      await sc.initialize();
      await sc.setEnabled(true);
      await sa.invite();
      await sc.pair(sa.state.invitation!);
      await sa.approve('c');
      await sc.synchronize();
      await sa.synchronize();
      await settle();
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        'relay edit',
        'message',
      ]);
      await b.repo.capture();
      final page = await b.repo.manifest();
      final item = (page['items'] as List).firstWhere(
        (item) => item['kind'] == 'messages',
      );
      final revision = await b.repo.revision(
        (item['hashes'] as List).single as String,
      );
      Future<void> push() async {
        await sb.transport.rpc(sb.peers.peers['a']!, {
          'method': 'put',
          'revision': revision.toJson(),
        });
      }

      await push();
      await settle();
      expect(
        (await c.local.read('messages', 'message'))!.payload['row']['content'],
        'relay edit',
      );
      final captures = (a.repo as LanCountingRepository).captures;
      await push();
      await settle();
      expect((a.repo as LanCountingRepository).captures, captures);
    },
  );

  test(
    'full reconciliation acknowledges the post-capture local watermark',
    () async {
      await seedLan(a);
      await automaticA();
      await pair();
      await settle();
      final local = a.repo as LanCountingRepository;
      final remote = b.repo as LanCountingRepository;
      // Model an overflow between the initial recent snapshot and the final
      // capture, without changing the independent remote continuity guard.
      local.simulateRecentOverflowOnCapture = local.captures + 1;
      await sa.synchronize();
      expect(local.simulateRecentOverflow, isTrue);
      final localPages = local.manifests, remotePages = remote.manifests;
      final captures = local.captures;
      notifyExternalSyncChange('direct.model');
      await waitFor(() => local.captures > captures);
      await settle();
      expect(local.manifests, localPages);
      expect(remote.manifests, remotePages);
    },
  );

  test(
    'recent eviction after baseline falls back to full reconciliation',
    () async {
      await seedLan(a);
      await automaticA();
      await pair();
      await settle();
      final local = a.repo as LanCountingRepository;
      final remote = b.repo as LanCountingRepository;
      final beforeLocal = local.manifests, beforeRemote = remote.manifests;
      await a.local.db.transaction(() async {
        for (var i = 0; i < LanRepository.recentLimit + 1; i++) {
          await a.local.execute(
            'INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES(?,?,?,?,?)',
            ['overflow-$i', 'role', 'assistant', 'entry', i + 10],
          );
        }
      });
      await a.repo.capture(scanExternal: false);
      expect(
        (await a.repo.recentChanges())['evicted_revision'],
        greaterThan(0),
      );
      await a.local.db.customUpdate(
        'UPDATE messages SET content=? WHERE id=?',
        variables: const [Variable('overflow wake'), Variable('message')],
        updates: {a.local.db.messages},
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline) &&
          local.manifests == beforeLocal) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await settle();
      expect(local.manifests, greaterThan(beforeLocal));
      expect(remote.manifests, greaterThan(beforeRemote));
    },
  );

  test(
    'automatic edits use recent fast path; manual sync reconciles',
    () async {
      await seedLan(a);
      await automaticA();
      await pair();
      await settle();
      final local = a.repo as LanCountingRepository;
      final remote = b.repo as LanCountingRepository;
      final localBefore = local.manifests, remoteBefore = remote.manifests;
      await a.local.db.customUpdate(
        'UPDATE messages SET content=? WHERE id=?',
        variables: const [Variable('fast lane'), Variable('message')],
        updates: {a.local.db.messages},
      );
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(deadline)) {
        final doc = await b.local.read('messages', 'message');
        if (doc?.payload['row']['content'] == 'fast lane') break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await settle();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        'fast lane',
      );
      expect(local.manifests, localBefore);
      expect(remote.manifests, remoteBefore);
      await saveCloudPreference(
        a.local.preferences,
        'direct.model',
        'fast-model',
      );
      final settingDeadline = DateTime.now().add(const Duration(seconds: 8));
      while (DateTime.now().isBefore(settingDeadline) &&
          b.local.preferences.getString('direct.model') != 'fast-model') {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      await settle();
      expect(b.local.preferences.getString('direct.model'), 'fast-model');
      expect(local.manifests, localBefore);
      expect(remote.manifests, remoteBefore);
      await sa.synchronize();
      expect(local.manifests, greaterThan(localBefore));
      expect(remote.manifests, greaterThan(remoteBefore));
    },
  );

  test(
    'automatic LAN sync wakes on a committed edit without manual synchronize',
    () async {
      await seedLan(a);
      final timers = await automaticA(automaticB: true);
      await pair();
      final starts = da.starts, stops = da.stops;
      await sa.foreground(true);
      await sa.foreground(true);
      expect(da.starts, starts);
      expect(da.stops, stops);
      await a.local.db.customUpdate(
        'UPDATE messages SET content=? WHERE id=?',
        variables: const [Variable('自动传递'), Variable('message')],
        updates: {a.local.db.messages},
      );
      final deadline = DateTime.now().add(const Duration(seconds: 7));
      while (DateTime.now().isBefore(deadline)) {
        if ((await b.local.read(
              'messages',
              'message',
            ))!.payload['row']['content'] ==
            '自动传递') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '自动传递',
      );
      await settle();
      expect(timers.where((t) => t.isActive), isEmpty);
    },
  );
  test(
    'real HTTP merges both histories, foreground reconnect and pause preserve data',
    () async {
      await seedLan(a);
      await b.local.execute(
        'INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES(?,?,?,?,?)',
        ['tablet-role', '平板', '平板', 1, 1],
      );
      await pair();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '原文',
      );
      expect(await a.local.read('conversations', 'tablet-role'), isNotNull);
      expect(await a.local.rows('SELECT * FROM cloud_dirty'), isNotEmpty);
      await sb.foreground(false);
      expect(sb.transport.listening, false);
      expect(db.active, false);
      await a.local.execute('UPDATE messages SET content=? WHERE id=?', [
        '离线后修改',
        'message',
      ]);
      await sb.foreground(true);
      expect(sb.transport.listening, true);
      // An authenticated status request advertises this device's new port.
      await sb.synchronize();
      await sa.synchronize();
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '离线后修改',
      );
      await sa.setEnabled(false);
      expect(sa.transport.listening, false);
      expect(da.active, false);
      expect(await a.local.read('messages', 'message'), isNotNull);
      await sb.forget('a');
      expect(sb.state.peers, isEmpty);
    },
  );
  test(
    'later wallpaper clearing wins over a concurrent offline replacement on real HTTP',
    () async {
      await seedLan(a);
      final old = File('${root.path}/old.bin')..writeAsBytesSync([1, 2, 3]);
      await a.local.execute(
        'UPDATE conversations SET chat_background_image=? WHERE id=?',
        [old.path, 'role'],
      );
      await pair();
      final replacement = File('${root.path}/new.bin')
        ..writeAsBytesSync([4, 5, 6]);
      await a.local.execute(
        'UPDATE conversations SET chat_background_image=? WHERE id=?',
        [replacement.path, 'role'],
      );
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await b.local.execute(
        'UPDATE conversations SET chat_background_image=NULL WHERE id=?',
        ['role'],
      );
      await sa.synchronize();
      await sb.synchronize();
      expect(
        (await a.local.read(
          'conversations',
          'role',
        ))!.payload['row']['chat_background_image'],
        isNull,
      );
      expect(
        (await b.local.read(
          'conversations',
          'role',
        ))!.payload['row']['chat_background_image'],
        isNull,
      );
      expect(await a.repo.conflicts(), isEmpty);
      expect(await b.repo.conflicts(), isEmpty);
    },
  );
  test('role wallpaper uses receiver local path and exact bytes', () async {
    await seedLan(a);
    final file = File('${root.path}/wallpaper.bin');
    await file.writeAsBytes(
      List<int>.generate(lanChunkSize * 2 + 97, (i) => i % 251),
    );
    final original = await a.media.register(
      file.path,
      createdAtMs: 1,
      mimeType: 'image/unsupported',
      originalRequired: true,
    );
    await a.local.execute(
      'UPDATE conversations SET chat_background_image=? WHERE id=?',
      [original.originalPath, 'role'],
    );
    await pair();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await b.local.rows('SELECT * FROM lan_media_queue')).isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final downloaded = await b.media.original(
      original.asset.id,
      allowDownload: false,
    );
    expect(downloaded.path, isNot(original.originalPath));
    expect(await downloaded.readAsBytes(), await file.readAsBytes());
    expect(
      (await sha256.bind(downloaded.openRead()).first).toString(),
      original.asset.originalSha256,
    );
    final role = (await b.local.read('conversations', 'role'))!.payload['row'];
    expect(role['chat_background_image'], downloaded.path);
    expect(await b.local.rows('SELECT * FROM lan_media_queue'), isEmpty);
    final records = await b.media.records().toList();
    expect(records.length, 1);
  });
  test(
    'role deletion waits for message tombstones and never violates foreign keys',
    () async {
      await seedLan(a);
      await pair();
      await a.local.db.transaction(() async {
        await a.local.execute('DELETE FROM messages WHERE conversation_id=?', [
          'role',
        ]);
        await a.local.execute('DELETE FROM conversations WHERE id=?', ['role']);
      });
      await sb.synchronize();
      await sa.synchronize();
      expect(await b.local.read('conversations', 'role'), isNull);
      expect(await b.local.read('messages', 'message'), isNull);
      expect(
        await b.local.rows('SELECT * FROM lan_pending_deletions'),
        isEmpty,
      );
      expect(await b.local.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );
  test(
    'delete role vs offline chat retains data and explicit role restore converges',
    () async {
      await seedLan(a);
      await pair();
      await a.local.db.transaction(() async {
        await a.local.execute('DELETE FROM messages WHERE conversation_id=?', [
          'role',
        ]);
        await a.local.execute('DELETE FROM conversations WHERE id=?', ['role']);
      });
      await b.local.execute('UPDATE messages SET content=? WHERE id=?', [
        '手机离线编辑',
        'message',
      ]);
      await sb.synchronize();
      expect(await b.local.read('conversations', 'role'), isNotNull);
      expect(
        (await b.local.read('messages', 'message'))!.payload['row']['content'],
        '手机离线编辑',
      );
      final conflicts = await b.repo.conflicts();
      final role = conflicts.firstWhere(
        (group) => group.first.kind == 'conversations',
      );
      final retained = role.firstWhere((r) => !r.deleted);
      await sb.resolve([(retained, role.map((r) => r.hash).toList())]);
      final message = (await b.repo.conflicts()).firstWhere(
        (group) => group.first.kind == 'messages',
      );
      final edit = message.firstWhere((r) => !r.deleted);
      await sb.resolve([(edit, message.map((r) => r.hash).toList())]);
      await sb.synchronize();
      await sa.synchronize();
      expect(await a.local.read('conversations', 'role'), isNotNull);
      expect(
        (await a.local.read('messages', 'message'))!.payload['row']['content'],
        '手机离线编辑',
      );
      expect(await b.repo.conflicts(), isEmpty);
      expect(await a.local.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );
  test(
    'path tombstone retains identity without inventing a file or download task',
    () async {
      await seedLan(a);
      final missing = await a.media.unavailable(
        '/absent-wallpaper',
        createdAtMs: 1,
        mimeType: 'image/unknown',
      );
      await a.local.execute(
        'UPDATE conversations SET chat_background_image=? WHERE id=?',
        [missing.asset.reference, 'role'],
      );
      await pair();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final queue = await b.local.rows('SELECT * FROM lan_media_queue');
      expect(queue, isEmpty);
      expect(await sb.media.counts(), (0, 0));
      expect(await b.media.load(missing.asset.id), isNotNull);
      final destination = await b.media.originalDestination(missing.asset.id);
      expect(await File(destination).exists(), false);
    },
  );
  test(
    'soft-deleted and replaced messages receive identities without files over HTTP',
    () async {
      await seedLan(a);
      final file = File('${root.path}/historical.wav')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final record = await a.media.register(
        file.path,
        createdAtMs: 1,
        mimeType: 'audio/wav',
      );
      for (final replaced in [false, true]) {
        await a.local.execute(
          'INSERT INTO messages(id,conversation_id,role,content,created_at,raw_payload,deleted_at,replaced_by) VALUES(?,?,?,?,?,?,?,?)',
          [
            'history-$replaced',
            'role',
            'assistant',
            '',
            1,
            jsonEncode({'audioUrl': record.asset.reference}),
            replaced ? null : 2,
            replaced ? 'message' : null,
          ],
        );
      }
      await pair();
      expect(await b.media.load(record.asset.id), isNotNull);
      expect(await sb.media.counts(), (0, 0));
      expect(
        await File(await b.media.originalDestination(record.asset.id)).exists(),
        isFalse,
      );
      expect(
        (await b.local.read(
          'messages',
          'history-false',
        ))!.payload['row']['deleted_at'],
        2,
      );
      expect(
        (await b.local.read(
          'messages',
          'history-true',
        ))!.payload['row']['replaced_by'],
        'message',
      );
    },
  );
  test(
    'chunk transfer resumes persisted partial after disconnect and skips existing files',
    () async {
      await pair();
      final file = File('${root.path}/audio.bin');
      await file.writeAsBytes(
        List<int>.generate(lanChunkSize * 2 + 5, (i) => i % 241),
      );
      final record = await a.media.register(
        file.path,
        createdAtMs: 1,
        mimeType: 'audio/wav',
      );
      final peer = sb.peers.peers['a']!;
      var chunks = 0, fail = true;
      final interrupted = LanMedia(b.local, b.media, (p, body) async {
        if (body['method'] == 'chunk') {
          chunks++;
          if (fail && chunks == 2) {
            throw const SocketException('test connection lost');
          }
        }
        return sb.transport.rpc(p, body);
      });
      await interrupted.prepare(peer, [record.asset.id]);
      await interrupted.drain(sb.peers.peers, () => true);
      expect(await b.local.rows('SELECT * FROM lan_media_queue'), isNotEmpty);
      final parts = await b.media.root
          .list(recursive: true)
          .where((f) => f.path.endsWith('.lan-part'))
          .toList();
      expect(await File(parts.single.path).length(), lanChunkSize);
      fail = false;
      await interrupted.drain(sb.peers.peers, () => true);
      expect(chunks, 4);
      expect(
        await (await b.media.original(
          record.asset.id,
          allowDownload: false,
        )).readAsBytes(),
        await file.readAsBytes(),
      );
      await interrupted.prepare(peer, [record.asset.id]);
      await interrupted.drain(sb.peers.peers, () => true);
      expect(chunks, 4);
    },
  );
}
