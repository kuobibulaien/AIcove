import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import '../domain/lan_contract.dart';
import '../domain/lan_sync_port.dart';
import 'lan_discovery.dart';
import 'lan_media.dart';
import 'lan_repository.dart';
import 'lan_transport.dart';

class LanService implements LanSyncPort {
  LanService(
    this.repository,
    this.peers, {
    required this.discovery,
    bool loopback = false,
    this.automatic = true,
  }) {
    transport = LanTransport(repository.deviceId, peers, _rpc, () {
      unawaited(_publish());
    }, loopback: loopback);
    media = LanMedia(repository.local, repository.codec.media, transport.rpc);
  }
  final LanRepository repository;
  final LanPeerStore peers;
  final LanDiscovery discovery;
  final bool automatic;
  late final LanTransport transport;
  late final LanMedia media;
  final _changes = StreamController<LanSyncState>.broadcast();
  LanSyncState _state = const LanSyncState();
  @override
  LanSyncState get state => _state;
  @override
  Stream<LanSyncState> get changes => _changes.stream;
  Timer? _timer, _debounce;
  StreamSubscription<dynamic>? _dbChanges;
  Future<void>? _work, _files, _initializing, _backup;
  bool _enabled = false, _foreground = true, _closed = false;
  String _name = '', _notice = '两端连接同一 Wi-Fi 或热点，打开应用即可同步';
  String? _error;
  Future<void> _lifecycle = Future.value();
  bool get _active =>
      _enabled && _foreground && !_closed && transport.listening;

  @override
  Future<void> initialize() => _initializing ??= () async {
    await peers.load();
    _name =
        repository.local.preferences.getString('aicove.lan.name') ??
        (Platform.isAndroid || Platform.isIOS ? '我的手机或平板' : '我的电脑');
    _enabled =
        repository.local.preferences.getBool('aicove.lan.enabled') == true;
    await _reconcile();
    await _publish();
  }();
  Future<void> _publish() async {
    if (_closed) return;
    final conflicts = await repository.conflicts();
    final counts = await media.counts();
    if (_closed) return;
    _state = LanSyncState(
      enabled: _enabled,
      busy: _work != null || _files != null,
      name: _name,
      deviceId: repository.deviceId,
      invitation: transport.invitation?.expires.isAfter(DateTime.now()) == true
          ? transport.invitation?.code
          : null,
      peers: peers.peers.values
          .map(
            (p) => LanPeerView(
              p.id,
              p.name,
              pending: !p.approved,
              incoming: p.incoming,
              online: p.online,
              lastSync: p.lastSync,
              error: p.error,
            ),
          )
          .toList(),
      conflicts: conflicts,
      pendingFiles: counts.$1,
      unavailableFiles: counts.$2,
      notice: _notice,
      error: _error,
    );
    _changes.add(_state);
  }

  Future<void> _reconcile() => _lifecycle = _lifecycle
      .then((_) async {
        _timer?.cancel();
        _timer = null;
        _debounce?.cancel();
        _debounce = null;
        await _dbChanges?.cancel();
        _dbChanges = null;
        if (!_enabled || !_foreground || _closed) {
          await discovery.stop();
          await transport.stop();
          await _work;
          await _files;
          for (final p in peers.peers.values) {
            p.online = false;
          }
          return;
        }
        await transport.start();
        try {
          await discovery.start(repository.deviceId, transport.port, (
            id,
            endpoints,
          ) {
            final peer = peers.peers[id];
            if (peer == null || !_active) return;
            peer.endpoints = endpoints;
            unawaited(peers.save().catchError((Object _) {}));
            if (automatic) unawaited(synchronize());
          });
          _notice = '两端连接同一 Wi-Fi 或热点，打开应用即可同步';
        } catch (_) {
          _notice = '自动发现暂不可用，仍可通过配对码连接；地址变化后需要重新配对';
        }
        if (automatic && _active) {
          _timer = Timer.periodic(const Duration(seconds: 3), (_) {
            unawaited(_publish());
            unawaited(synchronize());
          });
          _dbChanges = repository.local.db.tableUpdates().listen((_) {
            _debounce ??= Timer(const Duration(milliseconds: 300), () {
              _debounce = null;
              unawaited(synchronize());
            });
          });
          unawaited(synchronize());
        }
      })
      .catchError((Object error) {
        _error = _message(error);
      });
  Future<void> _action(Future<void> Function() operation) async {
    try {
      _error = null;
      await operation();
    } catch (e) {
      _error = _message(e);
    }
    await _publish();
  }

  String _message(Object e) => e is LanSyncFailure
      ? e.message
      : e is IOException
      ? '局域网连接或本地文件读取失败，已有数据已保留'
      : '局域网同步失败，已有数据已保留，请稍后重试';
  @override
  Future<void> setEnabled(bool enabled) => _action(() async {
    if (!await repository.local.preferences.setBool(
      'aicove.lan.enabled',
      enabled,
    )) {
      throw const LanSyncFailure('同步开关保存失败');
    }
    _enabled = enabled;
    await _reconcile();
  });
  @override
  Future<void> foreground(bool active) => _action(() async {
    _foreground = active;
    await _reconcile();
  });
  @override
  Future<void> setName(String name) => _action(() async {
    final value = name.trim();
    if (value.isEmpty || value.length > 50) {
      throw const LanSyncFailure('设备名称需要 1～50 个字');
    }
    if (!await repository.local.preferences.setString(
      'aicove.lan.name',
      value,
    )) {
      throw const LanSyncFailure('设备名称保存失败');
    }
    _name = value;
    transport.invitation = null;
  });
  @override
  Future<void> invite() => _action(() async {
    await transport.invite(_name);
  });
  @override
  Future<void> pair(String code) => _action(() async {
    if (!_active) throw const LanSyncFailure('请先开启局域网同步');
    await transport.pair(code, _name);
    _notice = '已发出配对请求，请在另一台设备确认';
  });
  @override
  Future<void> approve(String id) => _action(() async {
    final peer = peers.peers[id];
    if (peer == null || !peer.incoming) {
      throw const LanSyncFailure('请在发出邀请的设备确认配对');
    }
    peer.approved = true;
    await peers.save();
    if (automatic) unawaited(synchronize());
  });
  @override
  Future<void> forget(String id) => _action(() async {
    peers.peers.remove(id);
    await peers.save();
    await repository.local.execute(
      'DELETE FROM lan_media_queue WHERE peer_id=?',
      [id],
    );
    _notice = '已取消配对，本机历史保留';
    await repository.local.execute(
      'DELETE FROM lan_pending_deletions WHERE peer_id=?',
      [id],
    );
  });
  Future<void> _ensureBackup(LanPeer peer) async {
    if (peer.backedUp) return;
    await (_backup ??= repository.local.backup().then<void>((_) {}));
    peer.backedUp = true;
    await peers.save();
  }

  Future<void> _receive(LanPeer peer, LanRevision revision) async {
    await _ensureBackup(peer);
    if (!_active || peers.peers[peer.id] != peer || !peer.approved) {
      throw const LanSyncFailure('设备连接已停止');
    }
    if (revision.kind == 'conversations' && revision.deleted) {
      await repository.local.execute(
        'INSERT OR IGNORE INTO lan_pending_deletions(hash,peer_id,document_json) VALUES(?,?,?)',
        [revision.hash, peer.id, jsonEncode(revision.toJson())],
      );
      return;
    }
    if (!revision.deleted) await media.prepare(peer, revision.mediaIds);
    if (!_active || peers.peers[peer.id] != peer) {
      throw const LanSyncFailure('设备连接已停止');
    }
    await repository.receive(revision);
    unawaited(_publish());
  }

  Future<void> _drainDeletions(LanPeer peer, {bool strict = true}) async {
    final rows = await repository.local.rows(
      'SELECT * FROM lan_pending_deletions WHERE peer_id=? LIMIT 200',
      [peer.id],
    );
    for (final row in rows) {
      if (!_active || peers.peers[peer.id] != peer || !peer.approved) return;
      final revision = LanRevision.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(row['document_json'] as String) as Map,
        ),
      );
      try {
        await repository.receive(revision);
      } on LanSyncFailure {
        if (strict) rethrow;
        continue;
      }
      await repository.local.execute(
        'DELETE FROM lan_pending_deletions WHERE hash=?',
        [revision.hash],
      );
    }
  }

  Future<Map<String, dynamic>> _rpc(
    LanPeer peer,
    Map<String, dynamic> body,
  ) async {
    switch (body['method']) {
      case 'manifest':
        await repository.capture();
        return repository.manifest(after: body['after'] as String? ?? '');
      case 'missing':
        final hashes = (body['hashes'] as List).cast<String>();
        if (hashes.length > 200 ||
            hashes.any((h) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(h))) {
          throw const LanSyncFailure('同步摘要无效');
        }
        return {'hashes': await repository.missing(hashes)};
      case 'revision':
        return {
          'revision': (await repository.revision(
            body['hash'] as String,
          )).toJson(),
        };
      case 'put':
        await _receive(
          peer,
          LanRevision.fromJson(
            Map<String, dynamic>.from(body['revision'] as Map),
          ),
        );
        if (body['revision']['kind'] == 'messages' &&
            body['revision']['deleted'] == true) {
          await _drainDeletions(peer, strict: false);
        }
        return {'received': true};
      case 'media':
        return {'asset': await media.metadata(body['id'] as String)};
      case 'chunk':
        return media.chunk(
          body['id'] as String,
          body['digest'] as String,
          body['offset'] as int,
        );
      default:
        throw const LanSyncFailure('同步请求版本不支持');
    }
  }

  @override
  Future<void> synchronize() {
    if (!_active || peers.peers.isEmpty) return Future.value();
    return _work ??= _sync().whenComplete(() {
      _work = null;
      unawaited(_publish());
    });
  }

  Future<void> _sync() async {
    await _publish();
    try {
      await repository.capture();
      for (final peer in peers.peers.values.toList()) {
        if (!_active || peers.peers[peer.id] != peer) break;
        try {
          final status = await transport.rpc(peer, {
            'method': 'status',
            'name': _name,
            'endpoints': (await transport.addresses())
                .map((e) => e.toJson())
                .toList(),
          });
          if (status['approved'] != true) continue;
          if (!peer.approved) {
            peer.approved = true;
            await peers.save();
          }
          await _ensureBackup(peer);
          var after = '';
          do {
            final page = await transport.rpc(peer, {
              'method': 'manifest',
              'after': after,
            });
            final items = page['items'] as List;
            if (items.length > 200) throw const LanSyncFailure('同步摘要过大');
            for (final item in items) {
              final hashes = (item['hashes'] as List).cast<String>();
              if (hashes.length > 64) throw const LanSyncFailure('同时修改版本过多');
              for (final hash in await repository.missing(hashes)) {
                final reply = await transport.rpc(peer, {
                  'method': 'revision',
                  'hash': hash,
                });
                final revision = LanRevision.fromJson(
                  Map<String, dynamic>.from(reply['revision'] as Map),
                );
                if (revision.hash != hash ||
                    revision.kind != item['kind'] ||
                    revision.id != item['entity_id']) {
                  throw const LanSyncFailure('同步内容与摘要不一致');
                }
                await _receive(peer, revision);
              }
            }
            final next = page['after'] as String;
            if (page['has_more'] != true) break;
            if (next.compareTo(after) <= 0) {
              throw const LanSyncFailure('同步摘要分页无效');
            }
            after = next;
          } while (_active);
          await _drainDeletions(peer);
          await repository.capture();
          after = '';
          do {
            final page = await repository.manifest(after: after);
            for (final item in page['items'] as List) {
              final hashes = (item['hashes'] as List).cast<String>();
              final missing = await transport.rpc(peer, {
                'method': 'missing',
                'hashes': hashes,
              });
              for (final hash in (missing['hashes'] as List).cast<String>()) {
                if (!hashes.contains(hash)) {
                  throw const LanSyncFailure('同步摘要应答无效');
                }
                await transport.rpc(peer, {
                  'method': 'put',
                  'revision': (await repository.revision(hash)).toJson(),
                });
              }
            }
            after = page['after'] as String;
            if (page['has_more'] != true) break;
          } while (_active);
          peer.lastSync = DateTime.now();
          peer.online = true;
          peer.error = null;
        } catch (e) {
          peer.online = false;
          peer.error = _message(e);
        }
      }
      _error = null;
      if (_active) {
        _files ??= media
            .drain(peers.peers, () => _active)
            .catchError((Object _) {})
            .whenComplete(() {
              _files = null;
              unawaited(_publish());
            });
      }
    } catch (e) {
      _error = _message(e);
    }
  }

  @override
  Future<void> resolve(LanRevision selected, List<String> previewHashes) =>
      _action(() async {
        await repository.resolve(
          selected.kind,
          selected.id,
          selected.hash,
          previewHashes,
        );
        if (automatic) unawaited(synchronize());
      });
  @override
  Future<String> decodeQr(Uint8List bytes) async {
    if (bytes.length > 20 * 1024 * 1024) {
      throw const LanSyncFailure('二维码图片超过 20 MB');
    }
    return Isolate.run(() {
      final decoder = img.findDecoderForData(bytes);
      final info = decoder?.startDecode(bytes);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width * info.height > 16000000) {
        throw const LanSyncFailure('二维码图片无效或尺寸过大');
      }
      final image = decoder!.decodeFrame(0);
      if (image == null) throw const LanSyncFailure('二维码图片无效');
      final scaled = image.width > 1600 || image.height > 1600
          ? img.copyResize(
              image,
              width: image.width >= image.height ? 1600 : null,
              height: image.height > image.width ? 1600 : null,
            )
          : image;
      final source = RGBLuminanceSource(
        scaled.width,
        scaled.height,
        scaled
            .convert(numChannels: 4)
            .getBytes(order: img.ChannelOrder.abgr)
            .buffer
            .asInt32List(),
      );
      try {
        return QRCodeReader()
            .decode(BinaryBitmap(HybridBinarizer(source)))
            .text;
      } catch (_) {
        throw const LanSyncFailure('没有识别到配对二维码，请拍清晰些或粘贴配对码');
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    _enabled = false;
    await _reconcile();
    await _changes.close();
  }
}
