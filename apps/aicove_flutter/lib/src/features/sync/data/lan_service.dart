import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show listEquals;
import '../../../core/app_logger.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../../core/sync/cloud_tracking.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import '../domain/lan_contract.dart';
import '../domain/lan_sync_port.dart';
import 'cloud_document.dart';
import 'cloud_local_store.dart';
import 'lan_discovery.dart';
import 'lan_media.dart';
import 'lan_repository.dart';
import 'lan_transport.dart';
import 'device_names.dart';

class LanService implements LanSyncPort {
  LanService(
    this.repository,
    this.peers, {
    required this.discovery,
    bool loopback = false,
    this.automatic = true,
    this.scheduleTimer = Timer.new,
  }) {
    transport = LanTransport(
      repository.deviceId,
      peers,
      _rpc,
      _transportChanged,
      loopback: loopback,
      recentChanges: true,
      onPeerAvailable: _peerAvailable,
    );
    final discovery = this.discovery;
    if (discovery is LanDiscoveryLifecycle) {
      (discovery as LanDiscoveryLifecycle).onStopped = _recover;
    }
    media = LanMedia(repository.local, repository.codec.media, transport.rpc);
  }
  final LanRepository repository;
  final LanPeerStore peers;
  final LanDiscovery discovery;
  final bool automatic;
  final Timer Function(Duration, void Function()) scheduleTimer;
  late final LanTransport transport;
  late final LanMedia media;
  final _changes = StreamController<LanSyncState>.broadcast();
  LanSyncState _state = const LanSyncState();
  @override
  LanSyncState get state => _state;
  @override
  Stream<LanSyncState> get changes => _changes.stream;
  Timer? _invitationTimer, _retryTimer, _debounce, _progressTimer;
  LanInvitation? _scheduledInvitation;
  StreamSubscription<dynamic>? _dbChanges, _externalChanges;
  Future<void>? _work,
      _files,
      _initializing,
      _backup,
      _retrying,
      _recovering,
      _publishing;
  bool _syncAgain = false, _externalChanged = false;
  bool _metadataRetry = false, _recoveryNeeded = false;
  int _retryAttempts = 0;
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];
  bool _publishAgain = false;
  bool _enabled = false, _foreground = true, _closed = false;
  String _name = '', _notice = '两端连接同一 Wi-Fi 或热点，配对后自动保持连接';
  String? _error;
  Future<void> _lifecycle = Future.value();
  (String, int)? _advertised;
  final _nearby = <String, List<LanEndpoint>>{};
  final _pushedRecent = <String, String>{};
  final _pulledRecent = <String, String>{};
  int _roundPushed = 0, _roundPulled = 0, _roundFailed = 0;
  double _roundProgress = 0;
  bool _roundComplete = true;
  (double?, String)? _metadataProgress, _fileProgress;
  int _receiving = 0, _sendingFiles = 0;
  final _progressClock = Stopwatch()..start();
  int _lastProgressMs = -250;

  Future<void> _publishProgress({bool force = false}) {
    if (_closed) return Future.value();
    final now = _progressClock.elapsedMilliseconds;
    final remaining = 250 - (now - _lastProgressMs);
    if (!force && remaining > 0) {
      // Flush the latest state even if the last short operation already ended.
      _progressTimer ??= Timer(Duration(milliseconds: remaining), () {
        _progressTimer = null;
        unawaited(_publishProgress(force: true));
      });
      return Future.value();
    }
    _progressTimer?.cancel();
    _progressTimer = null;
    _lastProgressMs = now;
    return _publish();
  }

  Future<void> _metadata(String label, [double? progress]) {
    final prevPhase = _metadataProgress?.$2.split('（').first;
    final nextPhase = label.split('（').first;
    final changedPhase = prevPhase != nextPhase;
    if (progress != null) {
      _roundProgress = math.max(_roundProgress, progress.clamp(0.0, 1.0));
    }
    _metadataProgress = (
      progress != null
          ? _roundProgress
          : (_roundProgress > 0 ? _roundProgress : null),
      label,
    );
    return _publishProgress(force: changedPhase);
  }

  bool get _active =>
      _enabled && _foreground && !_closed && transport.listening;

  bool get _shouldRun => _enabled && _foreground && !_closed;

  void _transportChanged() {
    if (_closed) return;
    _refreshInvitationTimer();
    unawaited(_publish());
    if (_shouldRun && !transport.listening) _recover();
  }

  void _peerAvailable(LanPeer peer) {
    if (!automatic || !_active || peers.peers[peer.id] != peer) return;
    unawaited(synchronize());
  }

  void _recover() {
    if (!_shouldRun) return;
    _recoveryNeeded = true;
    if (_recovering != null) return;
    _recovering = _reconcile().whenComplete(() {
      _recovering = null;
      unawaited(_publish());
      _scheduleRetry();
    });
  }

  void _queueChange({bool external = false}) {
    if (!automatic || !_active) return;
    _externalChanged = _externalChanged || external;
    _debounce ??= Timer(const Duration(milliseconds: 300), () {
      _debounce = null;
      unawaited(_flushChanges());
    });
  }

  Future<void> _flushChanges() async {
    final external = _externalChanged;
    _externalChanged = false;
    if (!_active) return;
    try {
      if (external || await repository.hasPendingChanges()) {
        if (_active) await synchronize();
      }
    } catch (e) {
      _error = _message(e);
      _metadataRetry = true;
      await _publish();
    }
  }

  void _refreshInvitationTimer() {
    final invite = _shouldRun ? transport.invitation : null;
    if (identical(invite, _scheduledInvitation)) return;
    _invitationTimer?.cancel();
    _invitationTimer = null;
    _scheduledInvitation = invite;
    if (invite == null) return;
    final remaining = invite.expires.difference(DateTime.now());
    _invitationTimer = scheduleTimer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        if (!identical(_scheduledInvitation, invite)) return;
        _invitationTimer = null;
        _scheduledInvitation = null;
        if (identical(transport.invitation, invite)) {
          transport.invitation = null;
          unawaited(_publish());
        }
      },
    );
  }

  bool get _hasPendingApproval =>
      peers.peers.values.any((peer) => !peer.incoming && !peer.approved);

  void _scheduleRetry() {
    final needed =
        _shouldRun &&
        (_recoveryNeeded ||
            (automatic &&
                ((_metadataRetry && peers.peers.isNotEmpty) ||
                    _hasPendingApproval ||
                    _state.pendingFiles > 0)));
    if (!needed) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryAttempts = 0;
      return;
    }
    if (_retryTimer != null ||
        _retrying != null ||
        _recovering != null ||
        _work != null ||
        _files != null ||
        _retryAttempts >= _retryDelays.length) {
      return;
    }
    _retryTimer = scheduleTimer(_retryDelays[_retryAttempts++], () {
      _retryTimer = null;
      _retrying = _retry().whenComplete(() {
        _retrying = null;
        _scheduleRetry();
      });
    });
  }

  Future<void> _retry() async {
    if (!_shouldRun) return;
    try {
      if (_recoveryNeeded) await _reconcile();
      if (!_active || !automatic) return;
      if (_metadataRetry) {
        await _synchronize();
      } else {
        for (final peer in peers.peers.values.toList()) {
          if (!_active || peers.peers[peer.id] != peer) break;
          if ((!peer.incoming && !peer.approved) ||
              (_state.pendingFiles > 0 && peer.approved && !peer.online)) {
            try {
              final status = await _status(peer);
              if (!_active || peers.peers[peer.id] != peer) continue;
              if (!peer.approved && status['approved'] == true) {
                peer.approved = true;
                await peers.save();
                await _synchronize();
              }
            } catch (e) {
              peer.error = _message(e);
            }
          }
        }
      }
      if (_state.pendingFiles > 0) _startFiles();
      await _files;
    } catch (e) {
      _error = _message(e);
    } finally {
      await _publish();
    }
  }

  @override
  Future<void> initialize() => _initializing ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) {
    // Let a later call retry instead of replaying the cached failure.
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });
  Future<void> _initialize() async {
    await repository.local.normalizeLegacyMessageMedia();
    await media.reconcileQueue();
    await peers.load();
    _name = await ownDeviceName(repository.local.preferences);
    await publishDeviceName(repository.local.preferences, repository.deviceId);
    _enabled =
        repository.local.preferences.getBool('aicove.lan.enabled') == true;
    await _reconcile();
    await _publish();
  }

  Future<void> _publish() {
    if (_closed) return Future.value();
    _publishAgain = true;
    return _publishing ??= _flushPublish();
  }

  Future<void> _flushPublish() async {
    try {
      do {
        _publishAgain = false;
        await _publishState();
      } while (_publishAgain && !_closed);
    } finally {
      _publishing = null;
    }
  }

  Future<void> _publishState() async {
    if (_closed) return;
    final conflicts = await repository.conflicts();
    if (_closed) return;
    final counts = await media.counts();
    if (_closed) return;
    if (transport.invitation?.expires.isAfter(DateTime.now()) == false) {
      transport.invitation = null;
    }
    _refreshInvitationTimer();
    final progress =
        _fileProgress ??
        _metadataProgress ??
        (_receiving > 0
            ? (null, '正在接收聊天与设置')
            : _sendingFiles > 0
            ? (null, '正在发送附件')
            : null);
    final next = LanSyncState(
      enabled: _enabled,
      busy: progress != null,
      progress: progress?.$1,
      progressLabel: progress?.$2,
      name: _name,
      deviceId: repository.deviceId,
      invitation: transport.invitation?.expires.isAfter(DateTime.now()) == true
          ? transport.invitation?.code
          : null,
      pin: transport.invitation?.pinOpen == true
          ? transport.invitation?.pin
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
    if (_sameState(_state, next)) {
      _scheduleRetry();
      return;
    }
    _state = next;
    _changes.add(_state);
    _scheduleRetry();
  }

  bool _sameState(LanSyncState a, LanSyncState b) {
    Object fields(LanSyncState s) => (
      s.enabled,
      s.busy,
      s.progress,
      s.progressLabel,
      s.name,
      s.deviceId,
      s.invitation,
      s.pin,
      s.pendingFiles,
      s.unavailableFiles,
      s.notice,
      s.error,
    );
    Object peerFields(LanPeerView p) =>
        (p.id, p.name, p.pending, p.incoming, p.online, p.lastSync, p.error);
    if (fields(a) != fields(b) ||
        !listEquals(
          a.peers.map(peerFields).toList(),
          b.peers.map(peerFields).toList(),
        ) ||
        a.conflicts.length != b.conflicts.length) {
      return false;
    }
    for (var i = 0; i < a.conflicts.length; i++) {
      if (!listEquals(
        a.conflicts[i].map((r) => r.hash).toList(),
        b.conflicts[i].map((r) => r.hash).toList(),
      )) {
        return false;
      }
    }
    return true;
  }

  Future<void> _reconcile() => _lifecycle = _lifecycle
      .then((_) async {
        _retryTimer?.cancel();
        _retryTimer = null;
        _debounce?.cancel();
        _debounce = null;
        _externalChanged = false;
        await _dbChanges?.cancel();
        _dbChanges = null;
        await _externalChanges?.cancel();
        _externalChanges = null;
        if (!_enabled || !_foreground || _closed) {
          _invitationTimer?.cancel();
          _invitationTimer = null;
          _scheduledInvitation = null;
          _recoveryNeeded = false;
          _syncAgain = false;
          _advertised = null;
          await discovery.stop();
          _nearby.clear();
          await transport.stop();
          await _work;
          await _files;
          for (final p in peers.peers.values) {
            p.online = false;
          }
          return;
        }
        final listenerLost = !transport.listening;
        await transport.start();
        _recoveryNeeded = false;
        final advertised = (repository.deviceId, transport.port);
        if (listenerLost || !discovery.isRunning || _advertised != advertised) {
          _advertised = null;
          try {
            await discovery.start(repository.deviceId, transport.port, (
              id,
              endpoints,
            ) {
              _nearby[id] = endpoints;
              final peer = peers.peers[id];
              if (peer == null || !_active) return;
              final same = listEquals(
                peer.endpoints.map((e) => (e.host, e.port)).toList(),
                endpoints.map((e) => (e.host, e.port)).toList(),
              );
              if (same && peer.online && peer.error == null) return;
              peer.endpoints = endpoints;
              unawaited(peers.save().catchError((Object _) {}));
              if (automatic) unawaited(synchronize());
            });
            _advertised = advertised;
            _notice = '两端连接同一 Wi-Fi 或热点，配对后自动保持连接';
          } catch (_) {
            _recoveryNeeded = true;
            _notice = '自动发现暂不可用，仍可通过配对码连接；地址变化后需要重新配对';
          }
        }
        if (automatic && _active) {
          _dbChanges = repository.local.db.tableUpdates().listen((updates) {
            if (updates.any(
              (update) => cloudTables.containsKey(update.table),
            )) {
              _queueChange();
            }
          });
          _externalChanges = externalSyncChanges.listen((key) {
            if (key == null || CloudLocalStore.syncPreference(key)) {
              _queueChange(external: true);
            }
          });
          unawaited(_synchronize());
        }
        _recoveryNeeded =
            _shouldRun && (!transport.listening || !discovery.isRunning);
        _scheduleRetry();
      })
      .catchError((Object error) {
        _error = _message(error);
        _recoveryNeeded = _shouldRun;
        _scheduleRetry();
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
    if (active &&
        _foreground &&
        _enabled &&
        !_closed &&
        transport.listening &&
        discovery.isRunning &&
        _advertised == (repository.deviceId, transport.port) &&
        (!automatic || _dbChanges != null)) {
      return;
    }
    _foreground = active;
    await _reconcile();
  });
  @override
  Future<void> setName(String name) => _action(() async {
    final value = name.trim();
    if (value.isEmpty || value.length > 50) {
      throw const LanSyncFailure('设备名称需要 1～50 个字');
    }
    if (!await repository.local.preferences.setString(lanNameKey, value)) {
      throw const LanSyncFailure('设备名称保存失败');
    }
    _name = value;
    transport.invitation = null;
    await publishDeviceName(repository.local.preferences, repository.deviceId);
    _queueChange(external: true);
  });
  @override
  Future<void> invite() => _action(() async {
    await transport.invite(_name);
  });
  @override
  Future<void> pair(String code) => _action(() async {
    if (!_active) throw const LanSyncFailure('请先开启局域网同步');
    final pin = code.replaceAll(RegExp(r'[\s-]'), '');
    if (RegExp(r'^\d{6}$').hasMatch(pin)) {
      await transport.pairPin(pin, _name, _nearby.values.expand((e) => e));
    } else {
      await transport.pair(code, _name);
    }
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
    _pushedRecent.remove(id);
    _pulledRecent.remove(id);
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
    try {
      await (_backup ??= repository.local.backup().then<void>((_) {}));
    } catch (_) {
      // A remembered failure would reject every later push until restart.
      _backup = null;
      throw const LanSyncFailure('接收前的本机备份没有完成，可能是存储空间不足，稍后自动重试');
    }
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
    final row = revision.payload['row'] as Map?;
    final inactiveMessage =
        revision.kind == 'messages' &&
        (row?['deleted_at'] != null || row?['replaced_by'] != null);
    final prepared = revision.deleted
        ? const <LanPreparedMedia>[]
        : await media.prepareIdentities(peer, revision.mediaIds);
    if (!_active || peers.peers[peer.id] != peer) {
      throw const LanSyncFailure('设备连接已停止');
    }
    await _applyRevision(peer, revision);
    if (!inactiveMessage && !revision.deleted) {
      await media.enqueuePrepared(peer, prepared);
    }
    _startFiles();
  }

  Future<void> _applyRevision(LanPeer peer, LanRevision revision) async {
    final relay =
        automatic &&
        peers.peers.values.any(
          (other) => other.id != peer.id && other.approved,
        );
    Future<String> heads() async => jsonEncode(
      await repository.local.rows(
        'SELECT heads_json,local_fingerprint FROM lan_entities WHERE kind=? AND entity_id=?',
        [revision.kind, revision.id],
      ),
    );
    final before = relay ? await heads() : null;
    await repository.receive(revision);
    if (relay && before != await heads()) _queueChange(external: true);
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
        await _applyRevision(peer, revision);
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
      case 'recent':
        return repository.recentChanges();
      case 'manifest':
        final after = body['after'] as String? ?? '';
        // Later pages still drain committed DB edits, but need not fingerprint
        // every unchanged preference/preset again for the same manifest walk.
        await repository.capture(scanExternal: after.isEmpty);
        return repository.manifest(after: after);
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
        _receiving++;
        try {
          await _publishProgress(force: !_state.busy);
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
        } finally {
          _receiving--;
          await _publishProgress(force: _receiving == 0);
        }
      case 'media':
        return {'asset': await media.metadata(body['id'] as String)};
      case 'chunk':
        _sendingFiles++;
        try {
          await _publishProgress(force: !_state.busy);
          return await media.chunk(
            body['id'] as String,
            body['digest'] as String,
            body['offset'] as int,
          );
        } finally {
          _sendingFiles--;
          await _publishProgress(force: _sendingFiles == 0);
        }
      default:
        throw const LanSyncFailure('同步请求版本不支持');
    }
  }

  @override
  Future<void> synchronize() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryAttempts = 0;
    return _synchronize();
  }

  Future<Map<String, dynamic>> _status(LanPeer peer) async =>
      transport.rpc(peer, {
        'method': 'status',
        'approved': peer.approved,
        'name': _name,
        'endpoints': (await transport.addresses())
            .map((e) => e.toJson())
            .toList(),
      });

  Future<void> _synchronize() {
    if (!_active || peers.peers.isEmpty) return Future.value();
    // A later request belongs to the next round, not to an old capture.
    _syncAgain = true;
    _startFiles();
    return _work ??= _drainSync();
  }

  Future<void> _drainSync() async {
    try {
      do {
        _syncAgain = false;
        await _sync();
        _metadataRetry = !_roundComplete;
      } while (_active && _syncAgain);
    } finally {
      _work = null;
      _metadataProgress = null;
      await _publish();
    }
  }

  void _startFiles() {
    if (!_active ||
        _files != null ||
        !peers.peers.values.any((peer) => peer.approved && peer.online)) {
      return;
    }
    _files = _transferFiles()
        .catchError((Object error) {
          AppLogger.warning(
            'LanSync',
            'Attachment transfer paused',
            metadata: {
              'category': 'sync',
              'event': 'lanFiles',
              'errorType': error.runtimeType.toString(),
            },
          );
        })
        .whenComplete(() {
          _files = null;
          _fileProgress = null;
          unawaited(_publish());
        });
  }

  Future<void> _transferFiles() async {
    await media.reconcileQueue();
    var completedFiles = 0;
    var totalFiles = 0;
    while (_active) {
      final before = await media.counts();
      if (before.$1 + before.$2 == 0) return;
      if (completedFiles + before.$1 > totalFiles) {
        totalFiles = completedFiles + before.$1;
      }
      final effectiveTotal = math.max(
        1,
        totalFiles > 0 ? totalFiles : completedFiles + before.$1 + before.$2,
      );
      if (_fileProgress == null) {
        _fileProgress = (
          (completedFiles / effectiveTotal).clamp(0.0, 1.0),
          '正在接收附件（${math.min(completedFiles + 1, effectiveTotal)} / $effectiveTotal）',
        );
        await _publishProgress(force: true);
      }
      await media.drain(
        peers.peers,
        () => _active,
        completedOffset: completedFiles,
        totalFiles: effectiveTotal,
        onProgress: (progress, label) {
          final nextProgress = progress != null && _fileProgress?.$1 != null
              ? math.max(_fileProgress!.$1!, progress)
              : progress;
          _fileProgress = (nextProgress, label);
          return _publishProgress();
        },
      );
      final after = await media.counts();
      if (before.$1 > after.$1) {
        completedFiles += before.$1 - after.$1;
      }
      await _publishProgress(force: true);
      // Continue successful batches immediately; unavailable/offline files retry
      // on the normal wake-up rather than spinning in a tight retry loop.
      if (after.$1 == 0 || after.$1 >= before.$1) return;
    }
  }

  void _recordEntity(
    String entityId,
    String kind,
    String phase,
    Stopwatch clock,
    Object? error,
  ) {
    if (error != null) {
      _roundFailed++;
    } else if (phase == 'send') {
      _roundPushed++;
    } else {
      _roundPulled++;
    }
    if (error == null && clock.elapsed < const Duration(seconds: 2)) return;
    final metadata = <String, dynamic>{
      'category': 'sync',
      'event': 'lanEntity',
      'entityId': entityId,
      'kind': kind,
      'phase': phase,
      'result': error == null ? 'success' : 'failed',
      'elapsedMs': clock.elapsedMilliseconds,
      if (error != null) 'errorType': error.runtimeType.toString(),
      // Local log only (diagnostic exports drop it): a peer's error text is
      // not trusted to be one of our fixed strings, so keep it short.
      if (error is LanSyncFailure) 'reason': _short(error.message),
      if (error is CloudSyncFailure) 'reason': _short(error.message),
    };
    if (error == null) {
      AppLogger.info(
        'LanSync',
        'Slow entity transfer completed',
        metadata: metadata,
      );
    } else {
      AppLogger.warning(
        'LanSync',
        'Entity transfer failed',
        metadata: metadata,
      );
    }
  }

  // Callers supply hashes already filtered once for the whole page.
  Future<bool> _pullItem(
    LanPeer peer,
    Map item,
    Future<void> Function() transferred,
  ) async {
    var ok = true;
    for (final hash in (item['hashes'] as List).cast<String>()) {
      LanRevision? revision;
      final clock = Stopwatch()..start();
      try {
        final reply = await transport.rpc(peer, {
          'method': 'revision',
          'hash': hash,
        });
        revision = LanRevision.fromJson(
          Map<String, dynamic>.from(reply['revision'] as Map),
        );
        if (revision.hash != hash ||
            revision.kind != item['kind'] ||
            revision.id != item['entity_id']) {
          throw const LanSyncFailure('同步内容与摘要不一致');
        }
        await _receive(peer, revision);
        _recordEntity(revision.id, revision.kind, 'receive', clock, null);
      } catch (e) {
        ok = false;
        _recordEntity(
          item['entity_id'] as String,
          item['kind'] as String,
          'receive',
          clock,
          e,
        );
      } finally {
        await transferred();
      }
    }
    return ok;
  }

  Future<bool> _pullPage(
    LanPeer peer,
    List items, {
    double startProgress = 0.15,
    double endProgress = 0.55,
  }) async {
    final hashes = <String>{};
    for (final item in items) {
      final itemHashes = (item['hashes'] as List).cast<String>();
      if (itemHashes.length > 64) throw const LanSyncFailure('同时修改版本过多');
      hashes.addAll(itemHashes);
    }
    final missing = (await repository.missing(hashes)).toSet();
    if (missing.isEmpty) return true;
    final total = missing.length;
    var done = 0;
    await _metadata('正在接收聊天与设置（已接收 $_roundPulled 条）', startProgress);
    var ok = true;
    for (final item in items) {
      final wanted = (item['hashes'] as List)
          .where(missing.contains)
          .toSet()
          .toList();
      if (wanted.isNotEmpty &&
          !await _pullItem(peer, {...item as Map, 'hashes': wanted}, () {
            done++;
            final p =
                startProgress + (endProgress - startProgress) * (done / total);
            return _metadata('正在接收聊天与设置（已接收 $_roundPulled 条）', p);
          })) {
        ok = false;
      }
      missing.removeAll(wanted);
    }
    return ok;
  }

  Future<bool> _pushRevision(LanPeer peer, String hash) async {
    final revision = await repository.revision(hash);
    final clock = Stopwatch()..start();
    try {
      await transport.rpc(peer, {
        'method': 'put',
        'revision': revision.toJson(),
      });
      _recordEntity(revision.id, revision.kind, 'send', clock, null);
      return true;
    } catch (e) {
      _recordEntity(revision.id, revision.kind, 'send', clock, e);
      return false;
    }
  }

  Future<bool> _pullRecent(
    LanPeer peer, {
    double startProgress = 0.06,
    double endProgress = 0.10,
  }) async {
    final page = await transport.rpc(peer, {'method': 'recent'});
    final token = page['token'] as String?;
    if (token != null && _pulledRecent[peer.id] == token) return true;
    final items = page['items'] as List;
    if (items.length > LanRepository.recentLimit * 2) {
      throw const LanSyncFailure('同步摘要过大');
    }
    final ok = await _pullPage(
      peer,
      items,
      startProgress: startProgress,
      endProgress: endProgress,
    );
    if (ok && token != null) _pulledRecent[peer.id] = token;
    return ok;
  }

  Future<bool> _pushWanted(
    LanPeer peer,
    List<String> hashes, {
    double startProgress = 0.60,
    double endProgress = 1.00,
  }) async {
    if (hashes.isEmpty) return true;
    var ok = true;
    await _metadata('正在发送聊天与设置（已发送 $_roundPushed 条）', startProgress);
    for (var index = 0; index < hashes.length; index++) {
      try {
        if (!await _pushRevision(peer, hashes[index])) ok = false;
      } catch (_) {
        ok = false;
      }
      final p =
          startProgress +
          (endProgress - startProgress) * ((index + 1) / hashes.length);
      await _metadata('正在发送聊天与设置（已发送 $_roundPushed 条）', p);
    }
    return ok;
  }

  Future<bool> _pushRecent(
    LanPeer peer,
    Map<String, dynamic> page, {
    double startProgress = 0.02,
    double endProgress = 0.06,
  }) async {
    final token = page['token'] as String?;
    if (token != null && _pushedRecent[peer.id] == token) return true;
    var ok = true;
    final hashes = {
      for (final item in page['items'] as List)
        ...(item['hashes'] as List).cast<String>(),
    }.toList();
    final missing = <String>{};
    for (var offset = 0; offset < hashes.length; offset += 200) {
      final batch = hashes.skip(offset).take(200).toList();
      final result = await transport.rpc(peer, {
        'method': 'missing',
        'hashes': batch,
      });
      for (final hash in (result['hashes'] as List).cast<String>()) {
        if (!batch.contains(hash)) throw const LanSyncFailure('同步摘要应答无效');
        missing.add(hash);
      }
    }
    ok = await _pushWanted(
      peer,
      hashes.where(missing.contains).toList(),
      startProgress: startProgress,
      endProgress: endProgress,
    );
    if (ok && token != null) _pushedRecent[peer.id] = token;
    return ok;
  }

  Future<void> _sync() async {
    final clock = Stopwatch()..start();
    _roundPushed = _roundPulled = _roundFailed = 0;
    _roundProgress = 0;
    _roundComplete = true;
    try {
      await _metadata('正在核对同步内容', 0.02);
      for (final peer in peers.peers.values.toList()) {
        if (!_active || peers.peers[peer.id] != peer) {
          _roundComplete = false;
          break;
        }
        try {
          if (peer.incoming && !peer.approved) continue;
          final status = await _status(peer);
          if (status['approved'] != true) continue;
          if (!peer.approved) {
            peer.approved = true;
            await peers.save();
          }
          await _ensureBackup(peer);
          _startFiles();
          var complete = await _pushRecent(
            peer,
            await repository.recentChanges(),
            startProgress: 0.02,
            endProgress: 0.06,
          );
          if (status['recent_changes'] == 1 &&
              !await _pullRecent(
                peer,
                startProgress: 0.06,
                endProgress: 0.10,
              )) {
            complete = false;
          }
          await _metadata('正在整理本机修改', 0.12);
          await repository.capture();
          var after = '';
          var pullScanned = 0;
          var pullTotal = 0;
          do {
            final page = await transport.rpc(peer, {
              'method': 'manifest',
              'after': after,
            });
            final items = page['items'] as List;
            if (items.length > 200) throw const LanSyncFailure('同步摘要过大');
            if (after.isEmpty && page['total'] is int) {
              pullTotal = page['total'] as int;
            }
            final estimatedTotal = math.max(
              pullTotal,
              pullScanned + items.length + (page['has_more'] == true ? 100 : 0),
            );
            final startFrac = estimatedTotal <= 0
                ? 0.0
                : (pullScanned / estimatedTotal).clamp(0.0, 1.0);
            final endFrac = estimatedTotal <= 0
                ? 1.0
                : ((pullScanned + items.length) / estimatedTotal).clamp(
                    0.0,
                    1.0,
                  );
            final sliceStart = 0.15 + 0.40 * startFrac;
            final sliceEnd = 0.15 + 0.40 * endFrac;
            await _metadata(
              _roundPulled > 0
                  ? '正在接收聊天与设置（已接收 $_roundPulled 条）'
                  : estimatedTotal > 0
                  ? '正在核对对方同步内容（$pullScanned / $estimatedTotal）'
                  : '正在核对对方同步内容',
              sliceStart,
            );
            if (!await _pullPage(
              peer,
              items,
              startProgress: sliceStart,
              endProgress: sliceEnd,
            )) {
              complete = false;
            }
            pullScanned += items.length;
            await _metadata(
              _roundPulled > 0
                  ? '正在接收聊天与设置（已接收 $_roundPulled 条）'
                  : estimatedTotal > 0
                  ? '正在核对对方同步内容（$pullScanned / $estimatedTotal）'
                  : '正在核对对方同步内容',
              sliceEnd,
            );
            final next = page['after'] as String;
            if (page['has_more'] != true) break;
            if (next.compareTo(after) <= 0) {
              throw const LanSyncFailure('同步摘要分页无效');
            }
            after = next;
            if (!await _pushRecent(
              peer,
              await repository.recentChanges(),
              startProgress: sliceEnd,
              endProgress: sliceEnd,
            )) {
              complete = false;
            }
            if (status['recent_changes'] == 1 &&
                !await _pullRecent(
                  peer,
                  startProgress: sliceEnd,
                  endProgress: sliceEnd,
                )) {
              complete = false;
            }
          } while (_active);
          await _metadata('正在同步删除记录', 0.56);
          await _drainDeletions(peer);
          await _metadata('正在整理本机修改', 0.58);
          await repository.capture();
          final fullPushToken =
              (await repository.recentChanges())['token'] as String?;
          after = '';
          var pushScanned = 0;
          var pushTotal = 0;

          do {
            if (after.isNotEmpty && await repository.hasPendingChanges()) {
              await repository.capture(scanExternal: false);
            }
            final page = await repository.manifest(after: after);
            final items = page['items'] as List;
            if (after.isEmpty && page['total'] is int) {
              pushTotal = page['total'] as int;
            }
            final estimatedTotal = math.max(
              pushTotal,
              pushScanned + items.length + (page['has_more'] == true ? 100 : 0),
            );
            final startFrac = estimatedTotal <= 0
                ? 0.0
                : (pushScanned / estimatedTotal).clamp(0.0, 1.0);
            final endFrac = estimatedTotal <= 0
                ? 1.0
                : ((pushScanned + items.length) / estimatedTotal).clamp(
                    0.0,
                    1.0,
                  );
            final sliceStart = 0.60 + 0.40 * startFrac;
            final sliceEnd = 0.60 + 0.40 * endFrac;
            await _metadata(
              _roundPushed > 0
                  ? '正在发送聊天与设置（已发送 $_roundPushed 条）'
                  : estimatedTotal > 0
                  ? '正在核对本机同步内容（$pushScanned / $estimatedTotal）'
                  : '正在核对本机同步内容',
              sliceStart,
            );
            final hashes = {
              for (final item in items)
                ...(item['hashes'] as List).cast<String>(),
            }.toList();
            final missingHashes = <String>{};
            // Existing peers already accept up to 200 hashes per request.
            // Avoid a network round-trip for every unchanged message.
            for (var offset = 0; offset < hashes.length; offset += 200) {
              final end = offset + 200 < hashes.length
                  ? offset + 200
                  : hashes.length;
              final batch = hashes.sublist(offset, end);
              final missing = await transport.rpc(peer, {
                'method': 'missing',
                'hashes': batch,
              });
              for (final hash in (missing['hashes'] as List).cast<String>()) {
                if (!batch.contains(hash)) {
                  throw const LanSyncFailure('同步摘要应答无效');
                }
                missingHashes.add(hash);
              }
            }
            if (!await _pushWanted(
              peer,
              hashes.where(missingHashes.contains).toList(),
              startProgress: sliceStart,
              endProgress: sliceEnd,
            )) {
              complete = false;
            }
            pushScanned += items.length;
            await _metadata(
              _roundPushed > 0
                  ? '正在发送聊天与设置（已发送 $_roundPushed 条）'
                  : estimatedTotal > 0
                  ? '正在核对本机同步内容（$pushScanned / $estimatedTotal）'
                  : '正在核对本机同步内容',
              sliceEnd,
            );
            after = page['after'] as String;
            if (page['has_more'] != true) break;
            if (!await _pushRecent(
              peer,
              await repository.recentChanges(),
              startProgress: sliceEnd,
              endProgress: sliceEnd,
            )) {
              complete = false;
            }
          } while (_active);
          complete = complete && _active;
          _roundComplete = _roundComplete && complete;
          if (complete) {
            peer.lastSync = DateTime.now();
            if (fullPushToken != null) {
              _pushedRecent[peer.id] = fullPushToken;
            }
          }
          peer.online = true;
          peer.error = complete ? null : '部分记录未同步，将在下一轮重试';
        } catch (e) {
          _roundComplete = false;
          _roundFailed++;
          peer.online = false;
          peer.error = _message(e);
        }
      }
      _error = null;
      _startFiles();
    } catch (e) {
      _roundComplete = false;
      _roundFailed++;
      _error = _message(e);
    } finally {
      AppLogger.info(
        'LanSync',
        'Entity synchronization round completed',
        metadata: {
          'category': 'sync',
          'event': 'lanRound',
          'phase': 'round',
          'result': _roundComplete ? 'success' : 'partial',
          'pushed': _roundPushed,
          'pulled': _roundPulled,
          'failed': _roundFailed,
          'complete': _roundComplete,
          'elapsedMs': clock.elapsedMilliseconds,
        },
      );
    }
  }

  @override
  Future<void> resolve(
    List<(LanRevision selected, List<String> previewHashes)> choices,
  ) => _action(() async {
    // A batch keeps going past items that changed meanwhile; they stay listed.
    Object? failure;
    var failed = 0;
    for (final (selected, previewHashes) in choices) {
      try {
        await repository.resolve(
          selected.kind,
          selected.id,
          selected.hash,
          previewHashes,
        );
      } catch (e) {
        failure ??= e;
        failed++;
      }
    }
    if (automatic) unawaited(synchronize());
    if (failure != null) {
      if (choices.length == 1) throw failure;
      throw LanSyncFailure('有 $failed 项内容已有新修改，请再处理一次');
    }
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
    _progressTimer?.cancel();
    _progressTimer = null;
    _enabled = false;
    await _reconcile();
    await _retrying;
    await _recovering;
    await _publishing;
    _metadataProgress = _fileProgress = null;
    _state = LanSyncState(
      name: _state.name,
      deviceId: _state.deviceId,
      peers: _state.peers,
      conflicts: _state.conflicts,
      pendingFiles: _state.pendingFiles,
      unavailableFiles: _state.unavailableFiles,
      notice: _state.notice,
      error: _state.error,
    );
    await _changes.close();
  }
}

String _short(String text) =>
    text.length <= 80 ? text : '${text.substring(0, 80)}…';
