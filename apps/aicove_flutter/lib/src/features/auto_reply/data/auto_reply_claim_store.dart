import 'dart:math';

import 'package:drift/drift.dart';

import '../../../core/database/database.dart';

/// 开始送达后中断、不再重试的触发器作废原因（前后台共用）。
const String interruptedDeliveryReason = '开始送达后中断，未重试';

/// 主动回复触发器执行权认领者标识。
class AutoReplyClaimOwner {
  static const String foreground = 'foreground';
  static const String background = 'background';
}

/// 一条认领记录当前的状态。
sealed class AutoReplyClaimState {
  const AutoReplyClaimState();
}

/// 没有认领，或进行中的认领已过租约。
final class AutoReplyClaimFree extends AutoReplyClaimState {
  const AutoReplyClaimFree();
}

/// 有一方正在执行，租约到 [leaseEndsAt]。
final class AutoReplyClaimHeld extends AutoReplyClaimState {
  const AutoReplyClaimHeld(this.leaseEndsAt);
  final DateTime leaseEndsAt;
}

/// 已开始送达（见 [AutoReplyClaimStore.beginDelivery]），不会再被接管。
final class AutoReplyClaimDelivered extends AutoReplyClaimState {
  const AutoReplyClaimDelivered({required this.startedAt, this.messageId});

  final DateTime startedAt;

  /// 送达的第一条消息编号；旧记录没有，按后台固定编号判断。
  final String? messageId;

  /// 开始送达超过一个租约仍未收尾：持有方已中断，可以由另一方补成终态。
  /// 在此之前持有方可能还在正常写入，另一方不得插手。
  bool isStalled(DateTime now) =>
      !startedAt.add(AutoReplyClaimStore.lease).isAfter(now);
}

/// 触发器执行权认领仓库。
///
/// 前台轮询链路与后台 WorkManager 链路在真正发送前都必须先认领：
/// 单条 upsert 语句由 SQLite 文件锁保证跨 isolate 原子性，
/// 认领失败说明另一条链路已经拿到执行权，本方直接放弃，杜绝重复发送。
///
/// 认领是带过期时间的租约（ADR0064 第二批 2f）：进行中的认领超过 [lease]
/// 未开始送达，视为持有方进程已被杀，下一次认领直接接管。每次认领得到唯一
/// 令牌，开始送达与释放都要校验令牌：被接管的旧持有方既不能写消息，也不能
/// 删掉新持有方的认领。
///
/// 生命周期约定：
/// - 生成完成、写消息之前：认领方调用 [beginDelivery]，成功才写；之后的认领
///   记录永久挡住另一方，随 24h 清理移除。生成阶段崩溃会在租约过期后重试；
///   写消息这一小段崩溃不再重试（至多一次，宁缺不重）。
/// - 可重试失败：认领方必须 [release]，让下一次重试可以重新认领。
/// - 不可重试失败/作废：记录保留至清理，无副作用。
class AutoReplyClaimStore {
  AutoReplyClaimStore(this._db);

  final AppDatabase _db;

  /// 进行中认领的租约时长：远长于一次生成，又能让崩溃后的重试当天补上。
  static const Duration lease = Duration(minutes: 10);

  static final Random _random = Random.secure();

  /// 尝试认领触发器执行权；返回本次认领的令牌，null 表示未认领到。
  /// 已开始送达的认领永不接管；进行中的认领只在租约过期后接管。
  Future<String?> tryClaim({
    required String triggerId,
    required String claimedBy,
    DateTime? now,
  }) async {
    final normalizedTriggerId = triggerId.trim();
    if (normalizedTriggerId.isEmpty) return null;
    final token = '$claimedBy#${_random.nextInt(1 << 32).toRadixString(36)}'
        '${_random.nextInt(1 << 32).toRadixString(36)}';
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final affected = await _db.customUpdate(
      'INSERT INTO auto_reply_trigger_claims '
      '(trigger_id, claimed_by, claimed_at, completed_at) '
      'VALUES (?, ?, ?, NULL) '
      'ON CONFLICT(trigger_id) DO UPDATE SET '
      'claimed_by = excluded.claimed_by, claimed_at = excluded.claimed_at '
      'WHERE auto_reply_trigger_claims.completed_at IS NULL '
      'AND auto_reply_trigger_claims.claimed_at < ?',
      variables: [
        Variable.withString(normalizedTriggerId),
        Variable.withString(token),
        Variable.withInt(timestamp),
        Variable.withInt(timestamp - lease.inMilliseconds),
      ],
      updateKind: UpdateKind.insert,
    );
    return affected > 0 ? token : null;
  }

  /// 生成完成、写消息之前调用：仍持有 [token] 时原子地标记为已开始送达并
  /// 返回 true；已被接管时返回 false，调用方不得写消息。[messageId] 是将要
  /// 写入的第一条消息编号，中断后据此判断消息是否已经写进去。
  Future<bool> beginDelivery(
    String triggerId,
    String token, {
    String? messageId,
    DateTime? now,
  }) async {
    final affected = await _db.customUpdate(
      'UPDATE auto_reply_trigger_claims SET completed_at = ?, message_id = ? '
      'WHERE trigger_id = ? AND claimed_by = ? AND completed_at IS NULL',
      variables: [
        Variable.withInt((now ?? DateTime.now()).millisecondsSinceEpoch),
        messageId == null
            ? const Variable<String>(null)
            : Variable.withString(messageId),
        Variable.withString(triggerId.trim()),
        Variable.withString(token),
      ],
      updateKind: UpdateKind.update,
    );
    return affected > 0;
  }

  /// 开始送达后写入失败、且确知什么都没写进去（事务已回滚）时调用：撤销
  /// [token] 的认领，让下一次重试可以重新认领。
  Future<void> abortDelivery(String triggerId, String token) async {
    await _db.customUpdate(
      'DELETE FROM auto_reply_trigger_claims '
      'WHERE trigger_id = ? AND claimed_by = ?',
      variables: [
        Variable.withString(triggerId.trim()),
        Variable.withString(token),
      ],
      updateKind: UpdateKind.delete,
    );
  }

  /// 释放仍由 [token] 持有、尚未开始送达的认领（可重试失败时调用）。
  Future<void> release(String triggerId, String token) async {
    final normalizedTriggerId = triggerId.trim();
    if (normalizedTriggerId.isEmpty) return;
    await _db.customUpdate(
      'DELETE FROM auto_reply_trigger_claims '
      'WHERE trigger_id = ? AND claimed_by = ? AND completed_at IS NULL',
      variables: [
        Variable.withString(normalizedTriggerId),
        Variable.withString(token),
      ],
      updateKind: UpdateKind.delete,
    );
  }

  /// 仍由 [token] 持有、尚未开始送达时把租约从 [now] 重新算起并返回 true。
  /// 失败收尾先续租再改触发器：续租成功后一个租约内没人能接管，检查与写入
  /// 之间不会被插队。
  Future<bool> renew(String triggerId, String token, {DateTime? now}) async {
    final affected = await _db.customUpdate(
      'UPDATE auto_reply_trigger_claims SET claimed_at = ? '
      'WHERE trigger_id = ? AND claimed_by = ? AND completed_at IS NULL',
      variables: [
        Variable.withInt((now ?? DateTime.now()).millisecondsSinceEpoch),
        Variable.withString(triggerId.trim()),
        Variable.withString(token),
      ],
      updateKind: UpdateKind.update,
    );
    return affected > 0;
  }

  /// [token] 仍是这条触发器当前的认领（无论是否已开始送达）。完成回调据此
  /// 判断自己是否已被接管，被接管就不得再改触发器状态。
  Future<bool> isCurrent(String triggerId, String token) async {
    final row = await _db.customSelect(
      'SELECT 1 FROM auto_reply_trigger_claims '
      'WHERE trigger_id = ? AND claimed_by = ?',
      variables: [
        Variable.withString(triggerId.trim()),
        Variable.withString(token),
      ],
    ).getSingleOrNull();
    return row != null;
  }

  Future<AutoReplyClaimState> stateOf(String triggerId, {DateTime? now}) async {
    final row = await _db.customSelect(
      'SELECT claimed_at, completed_at, message_id '
      'FROM auto_reply_trigger_claims WHERE trigger_id = ?',
      variables: [Variable.withString(triggerId.trim())],
    ).getSingleOrNull();
    if (row == null) return const AutoReplyClaimFree();
    final completedAt = row.data['completed_at'] as int?;
    if (completedAt != null) {
      return AutoReplyClaimDelivered(
        startedAt: DateTime.fromMillisecondsSinceEpoch(completedAt),
        messageId: row.data['message_id'] as String?,
      );
    }
    final leaseEndsAt = DateTime.fromMillisecondsSinceEpoch(
      row.data['claimed_at'] as int,
    ).add(lease);
    return leaseEndsAt.isAfter(now ?? DateTime.now())
        ? AutoReplyClaimHeld(leaseEndsAt)
        : const AutoReplyClaimFree();
  }

  /// 清理早于 [cutoff] 的认领记录（随触发器 24h 清理一起执行）。
  /// [keepTriggerIds] 是仍有效的触发器，它们的认领保留：清掉“已开始送达”
  /// 的记录会让触发器被重新认领、重复发送。
  Future<void> cleanupBefore(
    DateTime cutoff, {
    Set<String> keepTriggerIds = const {},
  }) async {
    final keep = keepTriggerIds.toList();
    await _db.customUpdate(
      'DELETE FROM auto_reply_trigger_claims WHERE claimed_at < ?'
      '${keep.isEmpty ? '' : ' AND trigger_id NOT IN (${List.filled(keep.length, '?').join(', ')})'}',
      variables: [
        Variable.withInt(cutoff.millisecondsSinceEpoch),
        for (final id in keep) Variable.withString(id),
      ],
      updateKind: UpdateKind.delete,
    );
  }
}
