import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_proactive_state.dart';

const _conversationProactiveStateStoreKey = 'aicove.proactive_states.v1';

class ConversationProactiveStateStorage {
  Future<Map<String, ConversationProactiveState>> loadStates() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_conversationProactiveStateStoreKey);
    if (raw == null || raw.isEmpty) return const {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};

      final result = <String, ConversationProactiveState>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty || entry.value is! Map) continue;
        final state = ConversationProactiveState.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
        );
        if (state.conversationId.isEmpty) continue;
        result[state.conversationId] = state;
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveStates(
    Map<String, ConversationProactiveState> states,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = <String, dynamic>{
      for (final entry in states.entries)
        if (entry.key.trim().isNotEmpty) entry.key: entry.value.toJson(),
    };
    await prefs.setString(
      _conversationProactiveStateStoreKey,
      jsonEncode(payload),
    );
  }
}
