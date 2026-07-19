import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// 主动回复触发器执行权认领者标识。
class AutoReplyClaimOwner {
  static const String foreground = 'foreground';
  static const String background = 'background';
}

/// 触发器执行权认领仓库。
///
/// 前台轮询链路与后台 WorkManager 链路在真正发送前都必须先认领：
/// `INSERT OR IGNORE` 由 SQLite 文件锁保证跨 isolate 原子性，
/// 认领失败说明另一条链路已经拿到执行权，本方直接放弃，杜绝重复发送。
///
/// 生命周期约定：
/// - 发送成功：认领记录保留（继续挡住迟到的另一方），随 24h 清理移除。
/// - 可重试失败：认领方必须 [release]，让下一次重试可以重新认领。
/// - 不可重试失败/作废：记录保留至清理，无副作用。
class AutoReplyClaimStore {
  AutoReplyClaimStore(this._db);

  final AppDatabase _db;

  /// 尝试认领触发器执行权；true = 本方获得唯一执行权。
  Future<bool> tryClaim({
    required String triggerId,
    required String claimedBy,
    DateTime? now,
  }) async {
    final normalizedTriggerId = triggerId.trim();
    if (normalizedTriggerId.isEmpty) return false;
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final affected = await _db.customUpdate(
      'INSERT OR IGNORE INTO auto_reply_trigger_claims '
      '(trigger_id, claimed_by, claimed_at) VALUES (?, ?, ?)',
      variables: [
        Variable.withString(normalizedTriggerId),
        Variable.withString(claimedBy),
        Variable.withInt(timestamp),
      ],
      updateKind: UpdateKind.insert,
    );
    return affected > 0;
  }

  /// 释放认领（可重试失败时调用，允许下一次尝试重新认领）。
  Future<void> release(String triggerId) async {
    final normalizedTriggerId = triggerId.trim();
    if (normalizedTriggerId.isEmpty) return;
    await _db.customUpdate(
      'DELETE FROM auto_reply_trigger_claims WHERE trigger_id = ?',
      variables: [Variable.withString(normalizedTriggerId)],
      updateKind: UpdateKind.delete,
    );
  }

  /// 清理早于 [cutoff] 的认领记录（随触发器 24h 清理一起执行）。
  Future<void> cleanupBefore(DateTime cutoff) async {
    await _db.customUpdate(
      'DELETE FROM auto_reply_trigger_claims WHERE claimed_at < ?',
      variables: [Variable.withInt(cutoff.millisecondsSinceEpoch)],
      updateKind: UpdateKind.delete,
    );
  }
}
