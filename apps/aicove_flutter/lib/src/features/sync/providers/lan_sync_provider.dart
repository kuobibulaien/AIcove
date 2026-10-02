import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/media/media_store.dart';
import '../../../core/storage/device_credential_storage.dart';
import '../data/cloud_local_store.dart';
import '../data/cloud_media_codec.dart';
import '../data/lan_discovery.dart';
import '../data/lan_repository.dart';
import '../data/lan_service.dart';
import '../data/lan_transport.dart';
import '../domain/lan_sync_port.dart';
import 'cloud_sync_provider.dart';

final lanSyncPortProvider = FutureProvider<LanSyncPort>((ref) async {
  bool disposed = false;
  LanService? owned;
  ref.onDispose(() {
    disposed = true;
    if (owned != null) unawaited(owned.close());
  });
  final db = ref.read(databaseProvider);
  final preferences = await SharedPreferences.getInstance();
  final documents = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  final media = await MediaStore.shared;
  if (disposed) throw StateError('LAN provider disposed during initialization');
  final repository = LanRepository(
    CloudLocalStore(db, preferences, documents, support),
    CloudMediaCodec(media, allowNetworkDownload: false),
    media.deviceId,
    onApplied: (kinds) =>
        ref.read(cloudSyncProvider.notifier).handleApplied(kinds),
  );
  final service = LanService(
    repository,
    LanPeerStore(const DeviceCredentialStorage()),
    discovery: BonjourLanDiscovery(),
  );
  owned = service;
  await service.initialize();
  return service;
});

final lanSyncStateProvider = StreamProvider<LanSyncState>((ref) async* {
  final service = await ref.watch(lanSyncPortProvider.future);
  yield service.state;
  yield* service.changes;
});
