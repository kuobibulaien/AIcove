/// Request-scoped filtering. Never writes filtered content back to raw history.
class ChatPluginContextPolicy {
  const ChatPluginContextPolicy(
      {required this.imageEnabled, required this.ttsEnabled});

  final bool imageEnabled;
  final bool ttsEnabled;

  bool allowsTool(String name) =>
      (imageEnabled || !const {'draw_image', 'image_context'}.contains(name)) &&
      (ttsEnabled || name != 'speak');

  /// Removes the entire disabled tag, including attributes and nested content.
  /// An unfinished opening tag hides the remaining text rather than leaking it.
  String filterText(String text) {
    if ((imageEnabled && ttsEnabled) || !text.contains('<')) return text;
    for (final tag in [if (!imageEnabled) 'image', if (!ttsEnabled) 'tts']) {
      final tokens = RegExp(
        '<(/?)$tag(?=[\\s/>])(?:"[^"]*"|\'[^\']*\'|[^\'">])*?>',
        caseSensitive: false,
      );
      final output = StringBuffer();
      var depth = 0;
      var cursor = 0;
      for (final match in tokens.allMatches(text)) {
        if (depth == 0) output.write(text.substring(cursor, match.start));
        final closing = match.group(1) == '/';
        if (closing) {
          if (depth > 0) depth--;
        } else if (!match.group(0)!.endsWith('/>')) {
          depth++;
        }
        cursor = match.end;
      }
      if (depth == 0) output.write(text.substring(cursor));
      text = output.toString();
    }
    return text;
  }

  dynamic _filterValue(dynamic value) {
    if (value is String) return filterText(value);
    if (value is List) return value.map(_filterValue).toList();
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _filterValue(entry.value),
      };
    }
    return value;
  }

  List<Map<String, dynamic>> filterMessages(
      List<Map<String, dynamic>> messages) {
    final removedCallIds = <String>{};
    for (final message in messages) {
      for (final call in (message['tool_calls'] as List? ?? const [])) {
        if (call is Map &&
            call['function'] is Map &&
            !allowsTool((call['function']['name'] ?? '').toString())) {
          removedCallIds.add((call['id'] ?? '').toString());
        }
      }
    }
    final result = <Map<String, dynamic>>[];
    for (final original in messages) {
      if ((original['role'] == 'tool' || original['role'] == 'function') &&
          (!allowsTool((original['name'] ?? '').toString()) ||
              removedCallIds.contains(original['tool_call_id']))) {
        continue;
      }
      final message = _filterValue(original) as Map<String, dynamic>;
      final calls = message['tool_calls'] as List?;
      if (calls != null) {
        final kept = calls
            .where((call) =>
                call is Map &&
                call['function'] is Map &&
                allowsTool((call['function']['name'] ?? '').toString()))
            .toList();
        if (kept.isEmpty) {
          message.remove('tool_calls');
        } else {
          message['tool_calls'] = kept;
        }
      }
      final function = message['function_call'];
      if (function is Map && !allowsTool((function['name'] ?? '').toString())) {
        message.remove('function_call');
      }
      final content = message['content'];
      if (content is List) {
        message['content'] = content
            .where((part) =>
                part is! Map ||
                part['type'] != 'text' ||
                (part['text'] ?? '').toString().trim().isNotEmpty)
            .toList();
      }
      final filtered = message['content'];
      final empty = filtered == null ||
          (filtered is String && filtered.trim().isEmpty) ||
          (filtered is List && filtered.isEmpty);
      if (empty &&
          !message.containsKey('tool_calls') &&
          !message.containsKey('function_call') &&
          message['role'] != 'tool' &&
          message['role'] != 'function') {
        continue;
      }
      result.add(message);
    }
    return result;
  }
}
