import 'dart:io';
import 'dart:convert';

import 'package:aicove_flutter/src/features/sync/data/lan_crypto.dart';
import 'package:aicove_flutter/src/features/sync/data/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lan_transport_test.dart' show LanMemoryCredentials;

void main() {
  late LanPeerStore hostStore, guestStore;
  late LanTransport host, guest;

  setUp(() async {
    hostStore = LanPeerStore(LanMemoryCredentials(), loopback: true);
    guestStore = LanPeerStore(LanMemoryCredentials(), loopback: true);
    host = LanTransport(
      'host',
      hostStore,
      (peer, body) async => {'ok': true},
      () {},
      loopback: true,
      preferredPort: 0,
    );
    guest = LanTransport(
      'guest',
      guestStore,
      (peer, body) async => {'ok': true},
      () {},
      loopback: true,
      preferredPort: 0,
    );
    await host.start();
    await guest.start();
    await guest.pair(await host.invite('Host'), 'Guest');
    hostStore.peers['guest']!.approved = true;
    guestStore.peers['host']!.approved = true;
  });

  tearDown(() async {
    await host.stop();
    await guest.stop();
  });

  test(
    'authenticated status prefers the observed offered source address',
    () async {
      await guest.rpc(guestStore.peers['host']!, {
        'method': 'status',
        'name': 'Guest',
        'endpoints': [
          {'host': '127.0.0.2', 'port': guest.port},
          {'host': '127.0.0.1', 'port': guest.port},
        ],
      });
      expect(hostStore.peers['guest']!.endpoints.map((e) => e.host), [
        '127.0.0.1',
        '127.0.0.2',
      ]);
    },
  );

  test(
    'observed addresses are never added unless the peer offers them',
    () async {
      await guest.rpc(guestStore.peers['host']!, {
        'method': 'status',
        'name': 'Guest',
        'endpoints': [
          {'host': '127.0.0.2', 'port': guest.port},
        ],
      });
      expect(hostStore.peers['guest']!.endpoints.map((e) => e.host), [
        '127.0.0.2',
      ]);
    },
  );

  test(
    'a verified working endpoint wins after a stale address list refresh',
    () async {
      final failing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var failedConnections = 0;
      failing.listen((request) async {
        failedConnections++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      addTearDown(() => failing.close(force: true));
      final peer = LanPeer.fromJson(
        guestStore.peers['host']!.toJson(),
        loopback: true,
      );
      guestStore.peers['host'] = peer;
      final endpoints = [
        LanEndpoint('127.0.0.1', failing.port),
        LanEndpoint('127.0.0.1', host.port),
      ];
      peer.endpoints = endpoints;
      expect((await guest.rpc(peer, {'method': 'data'}))['ok'], true);
      expect(failedConnections, 1);
      peer.endpoints = List.of(endpoints);
      expect((await guest.rpc(peer, {'method': 'data'}))['ok'], true);
      expect(
        failedConnections,
        1,
        reason:
            'A repeated advertisement must not put a failed interface first again.',
      );
    },
  );

  test(
    'a remembered endpoint is ignored after it leaves the offered list',
    () async {
      final peer = guestStore.peers['host']!;
      expect((await guest.rpc(peer, {'method': 'data'}))['ok'], true);
      final previousPort = host.port;
      await host.stop();
      final trap = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        previousPort,
      );
      var staleRequests = 0;
      trap.listen((request) async {
        staleRequests++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      addTearDown(() => trap.close(force: true));
      await host.start();
      peer.endpoints = await host.addresses();
      expect((await guest.rpc(peer, {'method': 'data'}))['ok'], true);
      expect(staleRequests, 0);
    },
  );

  test(
    'bulk sync exceeds ten thousand requests without disabling replay protection',
    () async {
      final peer = guestStore.peers['host']!;
      for (var i = 0; i < 10001; i++) {
        expect((await guest.rpc(peer, {'method': 'status'}))['approved'], true);
      }
      final envelope = await LanCrypto.seal(
        peer.key,
        {'method': 'status'},
        from: 'guest',
        to: 'host',
        requestId: 'bulk-replay-check',
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<int> replay() async {
        final request = await client.postUrl(peer.endpoints.first.uri('rpc'));
        request.persistentConnection = false;
        request.write(jsonEncode(envelope));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      expect(await replay(), 200);
      expect(await replay(), 403);
    },
  );
}
