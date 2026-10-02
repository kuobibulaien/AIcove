import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../../core/storage/device_credential_storage.dart';
import '../domain/lan_contract.dart';
import 'lan_crypto.dart';

const lanRequestLimit = 8 * 1024 * 1024;

bool lanAddress(String host, {bool loopback = false}) {
  final ip = InternetAddress.tryParse(host);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return (loopback && ip.isLoopback) ||
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254);
}

class LanEndpoint {
  const LanEndpoint(this.host, this.port);
  final String host;
  final int port;
  Uri uri(String path) =>
      Uri(scheme: 'http', host: host, port: port, path: '/lan/v1/$path');
  Map<String, dynamic> toJson() => {'host': host, 'port': port};
  factory LanEndpoint.fromJson(Map json, {bool loopback = false}) {
    if (json['host'] is! String ||
        !lanAddress(json['host'] as String, loopback: loopback) ||
        json['port'] is! int ||
        json['port'] < 1 ||
        json['port'] > 65535) {
      throw const LanSyncFailure('配对地址不是可用的局域网地址');
    }
    return LanEndpoint(json['host'] as String, json['port'] as int);
  }
}

class LanPeer {
  LanPeer({
    required this.id,
    required this.name,
    required this.key,
    required this.endpoints,
    this.approved = false,
    this.backedUp = false,
    this.incoming = true,
  });
  final String id, key;
  String name;
  List<LanEndpoint> endpoints;
  bool approved, backedUp, incoming;
  DateTime? lastSync;
  String? error;
  bool online = false;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'key': key,
    'endpoints': endpoints.map((e) => e.toJson()).toList(),
    'approved': approved,
    'backed_up': backedUp,
    'incoming': incoming,
  };
  factory LanPeer.fromJson(Map json, {bool loopback = false}) => LanPeer(
    id: json['id'] as String,
    name: json['name'] as String,
    key: json['key'] as String,
    endpoints: (json['endpoints'] as List)
        .map((e) => LanEndpoint.fromJson(e as Map, loopback: loopback))
        .toList(),
    approved: json['approved'] == true,
    backedUp: json['backed_up'] == true,
    incoming: json['incoming'] == true,
  );
}

class LanPeerStore {
  LanPeerStore(this.credentials, {this.loopback = false});
  final DeviceCredentialStorage credentials;
  final bool loopback;
  final peers = <String, LanPeer>{};
  Future<void> _writes = Future.value();
  Future<void> load() async {
    final value = await credentials.read(key: 'aicove.lan.peers.v1');
    if (value == null) return;
    final data = jsonDecode(value) as List;
    for (final row in data) {
      final peer = LanPeer.fromJson(row as Map, loopback: loopback);
      LanCrypto.key(peer.key);
      peers[peer.id] = peer;
    }
  }

  Future<void> save() {
    final operation = _writes
        .catchError((Object _) {})
        .then(
          (_) => credentials.write(
            key: 'aicove.lan.peers.v1',
            value: jsonEncode(peers.values.map((p) => p.toJson()).toList()),
          ),
        );
    _writes = operation;
    return operation;
  }
}

class LanInvitation {
  LanInvitation(this.id, this.name, this.key, this.expires, this.endpoints);
  final String id, name, key;
  final DateTime expires;
  final List<LanEndpoint> endpoints;
  String get code => Uri(
    scheme: 'aicove-lan',
    host: 'pair',
    queryParameters: {
      'v': '1',
      'data': base64Url.encode(
        utf8.encode(
          jsonEncode({
            'id': id,
            'name': name,
            'key': key,
            'expires': expires.millisecondsSinceEpoch,
            'endpoints': endpoints.map((e) => e.toJson()).toList(),
          }),
        ),
      ),
    },
  ).toString();
  static LanInvitation parse(String code, {bool loopback = false}) {
    if (code.length > 8192) throw const LanSyncFailure('配对码过长');
    try {
      final uri = Uri.parse(code.trim());
      if (uri.scheme != 'aicove-lan' ||
          uri.host != 'pair' ||
          uri.queryParameters['v'] != '1') {
        throw const FormatException();
      }
      final j =
          jsonDecode(
                utf8.decode(base64Url.decode(uri.queryParameters['data']!)),
              )
              as Map;
      final id = j['id'] as String, name = j['name'] as String;
      if (id.isEmpty || id.length > 100 || name.isEmpty || name.length > 50) {
        throw const FormatException();
      }
      final key = j['key'] as String;
      LanCrypto.key(key);
      final expires = DateTime.fromMillisecondsSinceEpoch(j['expires'] as int);
      if (!expires.isAfter(DateTime.now()) ||
          expires.isAfter(DateTime.now().add(const Duration(minutes: 11)))) {
        throw const LanSyncFailure('配对码已过期，请在另一台设备重新生成');
      }
      final endpoints = (j['endpoints'] as List)
          .map((e) => LanEndpoint.fromJson(e as Map, loopback: loopback))
          .toList();
      if (endpoints.isEmpty || endpoints.length > 8) {
        throw const FormatException();
      }
      return LanInvitation(id, name, key, expires, endpoints);
    } on LanSyncFailure {
      rethrow;
    } catch (_) {
      throw const LanSyncFailure('配对码无效，请复制完整配对码或导入二维码');
    }
  }
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> stream) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(const Duration(seconds: 12))) {
    if (buffer.length + chunk.length > lanRequestLimit) {
      throw const LanSyncFailure('同步请求过大');
    }
    buffer.add(chunk);
  }
  return Map<String, dynamic>.from(
    jsonDecode(utf8.decode(buffer.takeBytes())) as Map,
  );
}

typedef LanRpcHandler =
    Future<Map<String, dynamic>> Function(
      LanPeer peer,
      Map<String, dynamic> body,
    );

class LanTransport {
  LanTransport(
    this.deviceId,
    this.store,
    this.handle,
    this.changed, {
    this.loopback = false,
  });
  final String deviceId;
  final LanPeerStore store;
  final LanRpcHandler handle;
  final void Function() changed;
  final bool loopback;
  HttpServer? _server;
  HttpClient? _client;
  LanInvitation? invitation;
  final _replay = <String, DateTime>{};
  final _activeRequests = <Future<void>>{};
  int _active = 0;
  int _generation = 0;
  int get port => _server?.port ?? 0;
  bool get listening => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final generation = ++_generation;
    final server = await HttpServer.bind(
      loopback ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
      0,
    );
    if (generation != _generation) {
      await server.close(force: true);
      return;
    }
    _server = server;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    server.listen((request) {
      final operation = _serve(request);
      _activeRequests.add(operation);
      operation.whenComplete(() => _activeRequests.remove(operation));
    });
  }

  Future<void> stop() async {
    ++_generation;
    invitation = null;
    final server = _server;
    _server = null;
    _client?.close(force: true);
    _client = null;
    await server?.close(force: true);
    await Future.wait(_activeRequests.toList());
  }

  Future<List<LanEndpoint>> addresses() async {
    if (port == 0) throw const LanSyncFailure('请先开启局域网同步');
    if (loopback) return [LanEndpoint('127.0.0.1', port)];
    return [
      for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: true,
      ))
        for (final ip in nic.addresses)
          if (lanAddress(ip.address)) LanEndpoint(ip.address, port),
    ].take(8).toList();
  }

  Future<String> invite(String name) async {
    final endpoints = await addresses();
    if (endpoints.isEmpty) {
      throw const LanSyncFailure('没有可用的局域网地址，请连接同一 Wi-Fi 或热点');
    }
    invitation = LanInvitation(
      deviceId,
      name,
      await LanCrypto.randomKey(),
      DateTime.now().add(const Duration(minutes: 10)),
      endpoints,
    );
    return invitation!.code;
  }

  Future<void> pair(String code, String name) async {
    final invite = LanInvitation.parse(code, loopback: loopback);
    if (invite.id == deviceId) throw const LanSyncFailure('这是本机的配对码，请用另一台设备扫描');
    final existing = store.peers[invite.id];
    if (existing?.approved == true) {
      final previous = existing!.endpoints;
      existing.endpoints = invite.endpoints;
      try {
        final status = await rpc(existing, {
          'method': 'status',
          'name': name,
          'endpoints': (await addresses()).map((e) => e.toJson()).toList(),
        });
        if (status['approved'] != true) {
          throw const LanSyncFailure('对方已取消配对，请先在本机取消旧配对后重新连接');
        }
        await store.save();
        changed();
        return;
      } catch (_) {
        existing.endpoints = previous;
        rethrow;
      }
    }
    final peer = LanPeer(
      id: invite.id,
      name: invite.name,
      key: await LanCrypto.pairKey(invite.key, invite.id, deviceId),
      endpoints: invite.endpoints,
      incoming: false,
    );
    // Save before sending: the host may approve even if the reply is lost.
    store.peers[peer.id] = peer;
    await store.save();
    final body = {
      'name': name,
      'endpoints': (await addresses()).map((e) => e.toJson()).toList(),
    };
    await _send(peer, body, 'pair', secret: invite.key);
    changed();
  }

  Future<Map<String, dynamic>> rpc(LanPeer peer, Map<String, dynamic> body) =>
      _send(peer, body, 'rpc');
  Future<Map<String, dynamic>> _send(
    LanPeer peer,
    Map<String, dynamic> body,
    String path, {
    String? secret,
  }) async {
    final client = _client;
    if (client == null) throw const LanSyncFailure('局域网同步已暂停');
    final generation = _generation;
    final id = const Uuid().v4();
    final envelope = await LanCrypto.seal(
      secret ?? peer.key,
      body,
      from: deviceId,
      to: peer.id,
      requestId: id,
    );
    final bytes = utf8.encode(jsonEncode(envelope));
    if (bytes.length > lanRequestLimit) throw const LanSyncFailure('同步请求过大');
    for (final endpoint in peer.endpoints) {
      if (!lanAddress(endpoint.host, loopback: loopback)) continue;
      try {
        if (generation != _generation) throw const LanSyncFailure('局域网同步已暂停');
        final request = await client
            .postUrl(endpoint.uri(path))
            .timeout(const Duration(seconds: 6));
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200) {
          await response.drain<void>().timeout(const Duration(seconds: 3));
          throw const LanSyncFailure('另一端拒绝连接，请核对是否已确认或已取消配对');
        }
        final result = await LanCrypto.open(
          secret ?? peer.key,
          await _readJson(response).timeout(const Duration(seconds: 15)),
          from: peer.id,
          to: deviceId,
          requestId: id,
          response: true,
        );
        if (generation != _generation || store.peers[peer.id] != peer) {
          throw const LanSyncFailure('局域网连接已停止');
        }
        if (result['error'] is String) {
          throw LanSyncFailure(result['error'] as String);
        }
        peer.online = true;
        peer.error = null;
        return result;
      } on LanSyncFailure {
        rethrow;
      } on IOException {
        /* Try another local interface. */
      } on TimeoutException {
        /* Try another local interface. */
      }
    }
    peer.online = false;
    throw const LanSyncFailure('设备暂不可达，请保持两端应用打开并连接同一 Wi-Fi 或热点');
  }

  Future<void> _serve(HttpRequest request) async {
    _active++;
    String? secret, from, id;
    try {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      _replay.removeWhere((_, at) => at.isBefore(cutoff));
      if (_active > 4 ||
          _replay.length >= 10000 ||
          _server == null ||
          request.method != 'POST' ||
          !lanAddress(
            request.connectionInfo?.remoteAddress.address ?? '',
            loopback: loopback,
          ) ||
          !{'/lan/v1/rpc', '/lan/v1/pair'}.contains(request.uri.path) ||
          request.contentLength > lanRequestLimit) {
        throw const LanSyncFailure('连接不可用');
      }
      final envelope = await _readJson(
        request,
      ).timeout(const Duration(seconds: 12));
      from = envelope['from'] as String;
      id = envelope['request_id'] as String;
      if (from.isEmpty ||
          from.length > 100 ||
          id.length > 100 ||
          id.isEmpty ||
          from == deviceId) {
        throw const LanSyncFailure('设备编号无效');
      }
      final invite = invitation;
      final isPair = request.uri.path.endsWith('/pair');
      final peer = store.peers[from];
      if (isPair) {
        if (invite == null ||
            !invite.expires.isAfter(DateTime.now()) ||
            peer?.approved == true) {
          throw const LanSyncFailure('邀请不可用');
        }
        secret = invite.key;
      } else {
        if (peer == null) throw const LanSyncFailure('尚未配对');
        secret = peer.key;
      }
      final body = await LanCrypto.open(
        secret,
        envelope,
        from: from,
        to: deviceId,
        requestId: id,
      );
      final now = DateTime.now();
      _replay.removeWhere(
        (_, at) => now.difference(at) > const Duration(minutes: 10),
      );
      final replayId = '$from/$id';
      if (_replay.containsKey(replayId)) throw const LanSyncFailure('重复连接请求');
      _replay[replayId] = now;
      Map<String, dynamic> result;
      if (isPair) {
        final name = body['name'] as String;
        final endpoints = (body['endpoints'] as List)
            .map((e) => LanEndpoint.fromJson(e as Map, loopback: loopback))
            .toList();
        if (name.isEmpty ||
            name.length > 50 ||
            endpoints.isEmpty ||
            endpoints.length > 8) {
          throw const LanSyncFailure('设备名称或地址无效');
        }
        if (_server == null || invitation != invite) {
          throw const LanSyncFailure('邀请已停止');
        }
        store.peers[from] = LanPeer(
          id: from,
          name: name,
          key: await LanCrypto.pairKey(secret, from, deviceId),
          endpoints: endpoints,
        );
        await store.save();
        invitation = null;
        result = {'pending': true};
        changed();
      } else {
        if (_server == null || store.peers[from] != peer) {
          throw const LanSyncFailure('设备已取消配对');
        }
        if (body['method'] == 'status') {
          if (peer!.approved && body['endpoints'] is List) {
            final endpoints = (body['endpoints'] as List)
                .map((e) => LanEndpoint.fromJson(e as Map, loopback: loopback))
                .toList();
            final name = body['name'] as String;
            if (endpoints.isEmpty ||
                endpoints.length > 8 ||
                name.isEmpty ||
                name.length > 50) {
              throw const LanSyncFailure('设备名称或地址无效');
            }
            if (jsonEncode(endpoints.map((e) => e.toJson()).toList()) !=
                    jsonEncode(
                      peer.endpoints.map((e) => e.toJson()).toList(),
                    ) ||
                name != peer.name) {
              peer.endpoints = endpoints;
              peer.name = name;
              await store.save();
              changed();
            }
          }
          result = {'approved': peer.approved};
        } else {
          if (!peer!.approved) throw const LanSyncFailure('请先在另一端确认配对');
          try {
            result = await handle(peer, body);
          } on LanSyncFailure catch (error) {
            result = {'error': error.message};
          }
        }
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          await LanCrypto.seal(
            secret,
            result,
            from: deviceId,
            to: from,
            requestId: id,
            response: true,
          ),
        ),
      );
    } catch (_) {
      // Authentication failures do not reveal whether a device or record exists.
      request.response.statusCode = HttpStatus.forbidden;
    } finally {
      try {
        await request.response.close();
      } catch (_) {
        /* Peer left. */
      } finally {
        _active--;
      }
    }
  }
}
