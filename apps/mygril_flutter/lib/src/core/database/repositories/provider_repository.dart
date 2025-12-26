import 'package:drift/drift.dart';
import '../database.dart';

/// 渠道商 Repository
class ProviderRepository {
  final AppDatabase _db;

  ProviderRepository(this._db);

  /// 获取所有渠道商（不含已删除）
  Future<List<Provider>> getAll() async {
    return (_db.select(_db.providers)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.displayName)]))
        .get();
  }

  /// 获取启用的渠道商
  Future<List<Provider>> getEnabled() async {
    return (_db.select(_db.providers)
          ..where((t) => t.deletedAt.isNull() & t.enabled.equals(true))
          ..orderBy([(t) => OrderingTerm.asc(t.displayName)]))
        .get();
  }

  /// 获取单个渠道商
  Future<Provider?> getById(String id) async {
    return (_db.select(_db.providers)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 创建渠道商
  Future<void> insert(ProvidersCompanion data) async {
    await _db.into(_db.providers).insert(data);
  }

  /// 更新渠道商
  Future<void> update(String id, ProvidersCompanion data) async {
    await (_db.update(_db.providers)..where((t) => t.id.equals(id)))
        .write(data);
  }

  /// 软删除渠道商
  Future<void> softDelete(String id, int deletedAt, int purgeAt) async {
    await (_db.update(_db.providers)..where((t) => t.id.equals(id)))
        .write(ProvidersCompanion(
      deletedAt: Value(deletedAt),
      purgeAt: Value(purgeAt),
    ));
  }

  /// 恢复渠道商
  Future<void> restore(String id) async {
    await (_db.update(_db.providers)..where((t) => t.id.equals(id)))
        .write(const ProvidersCompanion(
      deletedAt: Value(null),
      purgeAt: Value(null),
    ));
  }

  /// 获取 since 之后更新的渠道商（用于同步）
  Future<List<Provider>> getChangesSince(int since) async {
    return (_db.select(_db.providers)
          ..where((t) => t.updatedAt.isBiggerThanValue(since)))
        .get();
  }

  /// 物理删除过期数据
  Future<int> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.delete(_db.providers)
          ..where((t) => t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .go();
  }
}
