import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_crypto.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_discovery.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_media.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_service.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'lan_repository_test.dart' show LanTestDevice, lanTestDevice, seedLan;
import 'lan_transport_test.dart' show LanMemoryCredentials;

class LanTestDiscovery implements LanDiscovery {
  bool active = false;
  void Function(String, List<LanEndpoint>)? found;
  @override
  Future<void> start(
    String id,
    int port,
    void Function(String, List<LanEndpoint>) found,
  ) async {
    active = true;
    this.found = found;
  }

  @override
  Future<void> stop() async {
    active = false;
  }
}

void main() {
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
      final guest = LanTransport('guest', guestStore, (p, b) async => {}, () {});
      await host.start();
      await guest.start();
      addTearDown(() async {
        await host.stop();
        await guest.stop();
      });
      if ((await host.addresses()).isEmpty ||
          host.port != lanPreferredPort) {
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
    'automatic LAN sync wakes on a committed edit without manual synchronize',
    () async {
      await seedLan(a);
      final aPeers = sa.peers, bPeers = sb.peers;
      await sa.close();
      await sb.close();
      sa = LanService(a.repo, aPeers, discovery: da, loopback: true);
      sb = LanService(b.repo, bPeers, discovery: db, loopback: true);
      await sa.initialize();
      await sb.initialize();
      await pair();
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
    'unavailable original stays an explicit durable gap and never invents a file',
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
      expect(queue.length, 1);
      expect(await sb.media.counts(), (0, 1));
      final destination = await b.media.originalDestination(missing.asset.id);
      expect(await File(destination).exists(), false);
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
