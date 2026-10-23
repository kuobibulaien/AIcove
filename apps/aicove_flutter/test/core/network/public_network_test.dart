import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:aicove_flutter/src/core/network/public_network.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late PublicNetwork network;
  final connected = <String>[];
  final resolved = <String>[];
  final hosts = <String?>[];
  setUp(() async {
    connected.clear();
    resolved.clear();
    hosts.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      hosts.add(request.headers.value(HttpHeaders.hostHeader));
      final path = request.uri.pathSegments;
      try {
        if (path.firstOrNull == 'redirect') {
          final count = int.parse(path[1]);
          if (count > 0) {
            request.response.statusCode = 302;
            request.response.headers.set('location', '/redirect/${count - 1}');
          } else {
            request.response.write('done');
          }
        } else if (path.firstOrNull == 'private') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://internal.example:${server.port}/',
          );
        } else if (path.firstOrNull == 'bytes') {
          request.response.add(Uint8List(int.parse(path[1])));
        } else if (path.firstOrNull == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          request.response.write('late');
        } else {
          request.response.write('hello');
        }
        await request.response.close();
      } catch (_) {
        /* The client deliberately aborts oversized responses. */
      }
    });
    network = PublicNetwork(
      resolve: (host) async {
        resolved.add(host);
        return [
          InternetAddress(host == 'internal.example' ? '10.0.0.1' : '8.8.8.8'),
        ];
      },
      connect: (address, port) {
        connected.add(address.address);
        return Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
      },
    );
  });
  tearDown(() async {
    network.close();
    await server.close(force: true);
  });
  Uri url(String path) =>
      Uri.parse('http://public.example:${server.port}/$path');

  test('injected resolver preserves original Host and DNS address while preserving the original Host', () async {
    final response = await network.fetch(url(''));
    expect(response.status, 200);
    expect(connected, ['8.8.8.8']);
    expect(resolved, ['public.example']);
    expect(hosts, ['public.example:${server.port}']);
  });
  for (final addresses in [
    ['127.0.0.1'],
    ['10.0.0.1'],
    ['8.8.8.8', '192.168.0.1'],
    ['::ffff:127.0.0.1'],
    ['::ffff:10.0.0.1'],
    ['::1'],
    ['fc00::1'],
    ['198.18.0.1'],
    ['fdfe:dcba:9876::4'],
  ]) {
    test('accepts local, fake-IP and ULA DNS sets: $addresses', () async {
      final denied = PublicNetwork(
        resolve: (_) async => addresses.map(InternetAddress.new).toList(),
        connect: (_, _) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
      );
      try {
        expect((await denied.fetch(url(''))).status, 200);
      } finally {
        denied.close();
      }
    });
  }
  test(
    'redirects can reach private DNS too',
    () async {
      expect((await network.fetch(url('private'))).status, 200);
      expect(resolved, ['public.example', 'internal.example']);
      expect(connected, ['8.8.8.8', '10.0.0.1']);
    },
  );
  for (final count in [4, 5, 6]) {
    test('redirect limit boundary $count', () async {
      final future = network.fetch(url('redirect/$count'));
      if (count <= 5) {
        expect((await future).status, 200);
        expect(resolved.length, count + 1);
      } else {
        await expectLater(future, throwsStateError);
        expect(resolved.length, 6);
      }
    });
  }
  for (final size in [
    8 * 1024 * 1024 - 1,
    8 * 1024 * 1024,
    8 * 1024 * 1024 + 1,
  ]) {
    test('fetch decoded response byte boundary $size', () async {
      final future = network.fetch(url('bytes/$size'));
      if (size <= PublicNetwork.maxResponseBytes) {
        expect((await future).bytes.length, size);
      } else {
        await expectLater(future, throwsStateError);
      }
    });
  }
  for (final seconds in [29, 30, 31]) {
    test('fetch timeout configuration boundary $seconds', () async {
      final future = network.fetch(
        url(''),
        timeout: Duration(seconds: seconds),
      );
      expect((await future).status, 200);
    });
  }
  test(
    'timeout covers waiting for response, not only connection or chunks',
    () async {
      await expectLater(
        network.fetch(url('slow'), timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
  test('late DNS after timeout cannot open a connection', () async {
    final gate = Completer<List<InternetAddress>>();
    var connects = 0;
    final client = PublicNetwork(
      resolve: (_) => gate.future,
      connect: (a, p) {
        connects++;
        return Socket.startConnect(a, p);
      },
    );
    try {
      await expectLater(
        client.fetch(url(''), timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      gate.complete([InternetAddress('8.8.8.8')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connects, 0);
    } finally {
      client.close();
    }
  });
  test(
    'public address classification normalizes mapped IPv4 and excludes special ranges',
    () {
      for (final address in [
        '8.8.8.8',
        '1.1.1.1',
        '192.2.1.1',
        '2001:4860:4860::8888',
        '::ffff:8.8.8.8',
      ]) {
        expect(
          PublicNetwork.isPublicAddress(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      }
      for (final address in [
        '0.0.0.0',
        '100.64.0.1',
        '169.254.1.1',
        '172.16.0.1',
        '192.0.2.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '::',
        '2001:db8::1',
        '3fff::1',
        '64:ff9b::a00:1',
        '2002:a00:1::',
      ]) {
        expect(
          PublicNetwork.isPublicAddress(InternetAddress(address)),
          isFalse,
          reason: address,
        );
      }
    },
  );
  test(
    'TLS validates the original hostname despite the pinned TCP address',
    () async {
      final certificate = File(
        'test/fixtures/network/public-network-test-cert.pem.txt',
      );
      final key = File('test/fixtures/network/public-network-test-key.pem.txt');
      final serverContext = SecurityContext()
        ..useCertificateChain(certificate.path)
        ..usePrivateKey(key.path);
      final secure = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      secure.listen((request) async {
        final received = await request.fold<int>(
          0,
          (size, chunk) => size + chunk.length,
        );
        if (request.uri.path == '/bulk') {
          request.response.headers.set('x-received', '$received');
          request.response.add(Uint8List(8 * 1024 * 1024));
        } else {
          request.response.write('tls');
        }
        await request.response.close();
      });
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(
          'test/fixtures/network/public-network-test-ca.pem.txt',
        );
      final pins = <String>[];
      final client = PublicNetwork(
        allowPrivateHosts: true,
        securityContext: trusted,
        resolve: (host) async {
          final values = await InternetAddress.lookup(
            host,
            type: InternetAddressType.IPv4,
          );
          pins.add(values.first.host);
          return values;
        },
      );
      try {
        expect(
          (await client.fetch(
            Uri.parse('https://localhost:${secure.port}/'),
          )).status,
          200,
        );
        await expectLater(
          client.fetch(Uri.parse('https://127.0.0.1:${secure.port}/')),
          throwsA(isA<HandshakeException>()),
        );
        expect(pins, ['localhost', '127.0.0.1']);
        final bulk = await client.fetch(
          Uri.parse('https://localhost:${secure.port}/bulk'),
          method: 'POST',
          body: Uint8List(4 * 1024 * 1024),
        );
        expect(bulk.bytes.length, 8 * 1024 * 1024);
        expect(bulk.headers['x-received'], '${4 * 1024 * 1024}');
      } finally {
        client.close();
        await secure.close(force: true);
      }
    },
  );

  test(
    'unreachable address retries only the already-validated DNS set',
    () async {
      final attempts = <String>[];
      final client = PublicNetwork(
        resolve: (_) async => [
          InternetAddress('8.8.8.8'),
          InternetAddress('1.1.1.1'),
        ],
        connect: (address, _) async {
          attempts.add(address.address);
          if (address.address == '8.8.8.8') {
            throw const SocketException('unreachable');
          }
          return Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        },
      );
      try {
        expect((await client.fetch(url(''))).status, 200);
        expect(attempts, ['8.8.8.8', '1.1.1.1']);
      } finally {
        client.close();
      }
    },
  );
  test('TLS handshake timeout closes the underlying TCP peer', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final closed = Completer<void>();
    listener.listen((socket) {
      peers.add(socket);
      socket.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
        onError: (Object _) {},
      );
    });
    final client = PublicNetwork(
      allowPrivateHosts: true,
      resolve: (host) =>
          InternetAddress.lookup(host, type: InternetAddressType.IPv4),
    );
    try {
      await expectLater(
        client.fetch(
          Uri.parse('https://localhost:${listener.port}/'),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(peers, isNotEmpty);
      await closed.future.timeout(const Duration(milliseconds: 500));
    } finally {
      client.close();
      for (final socket in peers) {
        socket.destroy();
      }
      await listener.close();
    }
  });
}
