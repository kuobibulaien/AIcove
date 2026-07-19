import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';

const _triggerStoreKey = 'aicove.auto_triggers.v1';
const _triggerLogStoreKey = 'aicove.auto_trigger_logs.v1';

class AutoReplyTriggerStorage {
  Future<List<AutoReplyTrigger>> loadTriggers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final triggers = decoded
            .whereType<Map>()
            .map((e) => AutoReplyTrigger.fromJson(e.cast<String, dynamic>()))
            .toList();

        // 旧数据迁移：conversationId 为空的触发器标记为 expired
        // 这些是没有 contactId 的旧数据，无法关联到具体会话
        return triggers.map((t) {
          if (t.conversationId.isEmpty && t.isActive) {
            return t.copyWith(
              status: AutoReplyTriggerStatus.expired,
              expireReason: '旧数据迁移：缺少会话关联',
            );
          }
          return t;
        }).toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> saveTriggers(List<AutoReplyTrigger> triggers) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(triggers.map((e) => e.toJson()).toList());
    await prefs.setString(_triggerStoreKey, payload);
  }

  Future<List<AutoReplyTriggerLog>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(_triggerLogStoreKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => AutoReplyTriggerLog.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> appendLog(AutoReplyTriggerLog log, {int keep = 200}) async {
    final logs = await loadLogs();
    final updated = [log, ...logs];
    final trimmed = updated.take(keep).toList();
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(trimmed.map((e) => e.toJson()).toList());
    await prefs.setString(_triggerLogStoreKey, payload);
  }

  Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_triggerLogStoreKey);
  }
}
