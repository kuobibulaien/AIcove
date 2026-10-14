import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import 'aicove_package.dart';
import 'package_store.dart';

/// Where installed packages live; tests override it with a temp folder.
final packageStoreProvider = FutureProvider<PackageStore>(
  (ref) => PackageStore.defaultStore(),
);

/// Installed declarative packages. Each one is registered as plugin
/// `pkg:<id>` by `pluginManagerProvider`.
final aicovePackagesProvider =
    StateNotifierProvider<AicovePackagesNotifier, List<AicovePackage>>(
      (ref) => AicovePackagesNotifier(ref.watch(packageStoreProvider.future)),
    );

class AicovePackagesNotifier extends StateNotifier<List<AicovePackage>> {
  AicovePackagesNotifier(this._store) : super(const []) {
    ready = _reload();
  }

  final Future<PackageStore> _store;
  late final Future<void> ready;

  static const _logTag = 'AicovePackages';

  Future<void> _reload() async {
    try {
      final packages = await (await _store).list();
      if (mounted) state = packages;
    } catch (e) {
      AppLogger.warning(_logTag, '读取已安装的包失败', metadata: {'error': '$e'});
    }
  }

  Future<AicovePackage> importDirectory(Directory directory) =>
      _change((store) => store.importDirectory(directory));

  Future<AicovePackage> importZip(List<int> bytes) =>
      _change((store) => store.importZip(bytes));

  Future<AicovePackage> importFiles(Map<String, List<int>> files) =>
      _change((store) => store.importFiles(files));

  Future<void> delete(String id) => _change((store) => store.delete(id));

  Future<T> _change<T>(Future<T> Function(PackageStore store) change) async {
    await ready;
    final result = await change(await _store);
    await _reload();
    return result;
  }
}
