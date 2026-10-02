import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/storage/device_credential_storage.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_crypto.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';

class LanMemoryCredentials extends DeviceCredentialStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

void main() {
  test(
    'crypto binds device, request and response and rejects tampering',
    () async {
      final key = await LanCrypto.randomKey();
      final box = await LanCrypto.seal(
        key,
        {'message': '秘密'},
        from: 'a',
        to: 'b',
        requestId: 'request',
      );
      expect(
        await LanCrypto.open(
          key,
          box,
          from: 'a',
          to: 'b',
          requestId: 'request',
        ),
        {'message': '秘密'},
      );
      for (final args in [
        ('x', 'b', 'request', false),
        ('a', 'b', 'wrong', false),
        ('a', 'b', 'request', true),
      ]) {
        await expectLater(
          LanCrypto.open(
            key,
            box,
            from: args.$1,
            to: args.$2,
            requestId: args.$3,
            response: args.$4,
          ),
          throwsA(isA<LanSyncFailure>()),
        );
      }
      final changed = {
        ...box,
        'ciphertext': base64Url.encode([1, 2, 3]),
      };
      await expectLater(
        LanCrypto.open(key, changed, from: 'a', to: 'b', requestId: 'request'),
        throwsA(isA<LanSyncFailure>()),
      );
      expect(
        await LanCrypto.pairKey(key, 'a', 'b'),
        await LanCrypto.pairKey(key, 'b', 'a'),
      );
      expect(
        await LanCrypto.pairKey(key, 'a', 'c'),
        isNot(await LanCrypto.pairKey(key, 'a', 'b')),
      );
    },
  );
  test(
    'pairing requires host approval, rejects replay/revocation and survives restart',
    () async {
      final aCredentials = LanMemoryCredentials(),
          bCredentials = LanMemoryCredentials();
      final aStore = LanPeerStore(aCredentials, loopback: true),
          bStore = LanPeerStore(bCredentials, loopback: true);
      var calls = 0;
      Future<Map<String, dynamic>> handler(
        LanPeer p,
        Map<String, dynamic> body,
      ) async {
        calls++;
        return {'ok': true};
      }

      final a = LanTransport('a', aStore, handler, () {}, loopback: true);
      final b = LanTransport('b', bStore, handler, () {}, loopback: true);
      await a.start();
      await b.start();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });
      final code = await a.invite('电脑');
      await b.pair(code, '手机');
      expect(aStore.peers['b']!.approved, false);
      await expectLater(
        b.rpc(bStore.peers['a']!, {'method': 'data'}),
        throwsA(isA<LanSyncFailure>()),
      );
      expect(calls, 0);
      aStore.peers['b']!.approved = true;
      await aStore.save();
      expect(
        (await b.rpc(bStore.peers['a']!, {'method': 'status'}))['approved'],
        true,
      );
      bStore.peers['a']!.approved = true;
      expect((await b.rpc(bStore.peers['a']!, {'method': 'data'}))['ok'], true);
      final peer = bStore.peers['a']!;
      final envelope = await LanCrypto.seal(
        peer.key,
        {'method': 'data'},
        from: 'b',
        to: 'a',
        requestId: 'replay',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> send(Map<String, dynamic> value) async {
        final req = await client.postUrl(peer.endpoints.first.uri('rpc'));
        req.write(jsonEncode(value));
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      expect(await send(envelope), 200);
      expect(await send(envelope), 403);
      expect(await send({...envelope, 'request_id': 'forged'}), 403);
      expect(calls, 2);
      await a.stop();
      await a.start();
      final restored = LanPeerStore(aCredentials, loopback: true);
      await restored.load();
      expect(restored.peers['b']!.key, aStore.peers['b']!.key);
      peer.endpoints = await a.addresses();
      expect((await b.rpc(peer, {'method': 'data'}))['ok'], true);
      // Refresh addresses with a newly scanned invitation using the retained key.
      final retainedKey = peer.key;
      peer.endpoints = [const LanEndpoint('127.0.0.1', 1)];
      await b.pair(await a.invite('电脑'), '手机');
      expect(peer.key, retainedKey);
      expect((await b.rpc(peer, {'method': 'data'}))['ok'], true);
      aStore.peers.remove('b');
      await aStore.save();
      await expectLater(
        b.rpc(peer, {'method': 'data'}),
        throwsA(isA<LanSyncFailure>()),
      );
    },
  );
  test(
    'expired invitations and public/DNS pairing addresses are rejected',
    () async {
      final key = await LanCrypto.randomKey();
      final expired = LanInvitation(
        'a',
        '电脑',
        key,
        DateTime.now().subtract(const Duration(seconds: 1)),
        [const LanEndpoint('192.168.1.2', 80)],
      );
      expect(
        () => LanInvitation.parse(expired.code),
        throwsA(isA<LanSyncFailure>()),
      );
      for (final host in ['8.8.8.8', 'example.com', '127.0.0.1', '0.0.0.0']) {
        expect(
          () => LanEndpoint.fromJson({'host': host, 'port': 80}),
          throwsA(isA<LanSyncFailure>()),
        );
      }
      expect(lanAddress('192.168.1.2'), true);
      expect(lanAddress('172.31.2.3'), true);
      expect(lanAddress('172.32.0.1'), false);
    },
  );
}
