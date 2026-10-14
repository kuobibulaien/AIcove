import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show FinishReason;

export 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show FinishReason;

/// Maps a provider's raw finish reason to [FinishReason] (batch 2 plan
/// §3.8): OpenAI `finish_reason`, Claude `stop_reason`, Gemini
/// `finishReason`. The raw names of the three do not collide, so one table
/// serves all. Null or blank means the provider reported none.
FinishReason? normalizeFinishReason(String? raw) {
  final value = raw?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  return switch (value) {
    'stop' || 'end_turn' || 'stop_sequence' => FinishReason.stop,
    'tool_calls' || 'function_call' || 'tool_use' => FinishReason.toolCalls,
    'length' || 'max_tokens' => FinishReason.length,
    'content_filter' ||
    'refusal' ||
    'safety' ||
    'recitation' ||
    'blocklist' ||
    'prohibited_content' ||
    'spii' ||
    'image_safety' =>
      FinishReason.contentFilter,
    _ => FinishReason.unknown,
  };
}
