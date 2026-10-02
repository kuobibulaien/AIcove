import 'dart:typed_data';
import 'lan_contract.dart';

class LanPeerView {
  const LanPeerView(
    this.id,
    this.name, {
    this.pending = false,
    this.incoming = false,
    this.online = false,
    this.lastSync,
    this.error,
  });
  final String id, name;
  final bool pending, online, incoming;
  final DateTime? lastSync;
  final String? error;
}

class LanSyncState {
  const LanSyncState({
    this.enabled = false,
    this.busy = false,
    this.name = '',
    this.deviceId = '',
    this.invitation,
    this.peers = const [],
    this.conflicts = const [],
    this.pendingFiles = 0,
    this.unavailableFiles = 0,
    this.notice,
    this.error,
  });
  final bool enabled, busy;
  final String name, deviceId;
  final String? invitation, notice, error;
  final List<LanPeerView> peers;
  final List<List<LanRevision>> conflicts;
  final int pendingFiles, unavailableFiles;
}

abstract interface class LanSyncPort {
  LanSyncState get state;
  Stream<LanSyncState> get changes;
  Future<void> initialize();
  Future<void> setEnabled(bool enabled);
  Future<void> setName(String name);
  Future<void> invite();
  Future<void> pair(String code);
  Future<String> decodeQr(Uint8List bytes);
  Future<void> approve(String peerId);
  Future<void> forget(String peerId);
  Future<void> synchronize();
  Future<void> resolve(LanRevision selected, List<String> previewHashes);
  Future<void> foreground(bool active);
  Future<void> close();
}
