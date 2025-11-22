import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'auto_reply_trigger.dart';

const _triggerStoreKey = 'mygril.auto_triggers.v1';
const _triggerLogStoreKey = 'mygril.auto_trigger_logs.v1';

class AutoReplyTriggerStorage {
  Future<List<AutoReplyTrigger>> loadTriggers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_triggerStoreKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => AutoReplyTrigger.fromJson(e.cast<String, dynamic>()))
            .toList();
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

  Future<void> appendLog(AutoReplyTriggerLog log, {int keep = 50}) async {
    final logs = await loadLogs();
    final updated = [log, ...logs];
    final trimmed = updated.take(keep).toList();
    final prefs = await SharedPreferences.getInstance();
    final payload = jsonEncode(trimmed.map((e) => e.toJson()).toList());
    await prefs.setString(_triggerLogStoreKey, payload);
  }
}
