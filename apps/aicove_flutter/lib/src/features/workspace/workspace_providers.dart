import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_data_directory.dart';
import 'data/workspace_store.dart';
import 'domain/workspace_models.dart';

/// The device's workspace store under `appDataDirectory()/workspaces`,
/// always holding the built-in AIcove workspace.
final workspaceStoreProvider = FutureProvider<WorkspaceStore>((ref) async {
  final root = Directory(p.join((await appDataDirectory()).path, 'workspaces'));
  final store = await WorkspaceStore.open(root);
  ref.onDispose(store.close);
  await store.ensureDefault();
  return store;
});

/// Workspaces registered on this device.
final workspacesProvider = FutureProvider<List<WorkspaceInfo>>((ref) async {
  final store = await ref.watch(workspaceStoreProvider.future);
  return store.list();
});
