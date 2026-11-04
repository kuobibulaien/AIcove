/// Removes single-image tags that conflict with manga generation.
abstract final class MangaPromptSanitizer {
  static bool hasSections(String prompt) => RegExp(
    r'(?:^|[,\n])\s*@(page|panel|character|position)\b',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(prompt);

  static bool isMultiple(String prompt) {
    final panels = RegExp(r'^\s*@panel\b', caseSensitive: false, multiLine: true).allMatches(prompt).length;
    final characters = RegExp(r'^\s*@character\b', caseSensitive: false, multiLine: true).allMatches(prompt).length;
    return panels > 1 || characters > 1 ||
        RegExp(r'\b(?:[2-9]\d*(?:girls?|boys?|women|men|persons?|people)|multiple\s+(?:girls|boys|people|women|men))\b', caseSensitive: false).hasMatch(prompt) ||
        (RegExp(r'\b1girl\b', caseSensitive: false).hasMatch(prompt) && RegExp(r'\b1boy\b', caseSensitive: false).hasMatch(prompt));
  }

  static String cleanTags(String input, Set<String> remove) {
    bool keep(String tag) {
      var normalized = tag.toLowerCase().trim();
      while (true) {
        final previous = normalized;
        normalized = normalized
            .replaceFirst(RegExp(r'^[-+]?\d*\.?\d*\s*::\s*'), '')
            .replaceFirst(RegExp(r'\s*::$'), '').trim();
        if (normalized.length >= 2 &&
            ((normalized.startsWith('(') && normalized.endsWith(')')) ||
             (normalized.startsWith('{') && normalized.endsWith('}')) ||
             (normalized.startsWith('[') && normalized.endsWith(']')))) {
          normalized = normalized.substring(1, normalized.length - 1).trim();
        }
        if (normalized == previous) break;
      }
      return normalized.isNotEmpty && !remove.contains(normalized);
    }
    final output = <String>[];
    final block = <String>[];
    String? weight;
    for (final part in input.split(RegExp(r'[,，\n]+'))) {
      var tag = part.trim();
      if (tag.isEmpty) continue;
      if (weight == null) {
        final start = RegExp(r'^([-+]?\d*\.?\d+\s*::)\s*').firstMatch(tag);
        if (start != null) {
          weight = start.group(1)!;
          tag = tag.substring(start.end).trim();
        } else if (tag.startsWith('::')) {
          tag = tag.substring(2).trim();
          if (tag.endsWith('::')) tag = tag.substring(0, tag.length - 2).trim();
        }
      }
      if (weight != null) {
        final closed = tag.endsWith('::');
        if (closed) tag = tag.substring(0, tag.length - 2).trim();
        if (keep(tag)) block.add(tag);
        if (closed) {
          if (block.isNotEmpty) {
            block[0] = '$weight${block[0]}';
            block[block.length - 1] = '${block.last}::';
            output.addAll(block);
          }
          block.clear();
          weight = null;
        }
      } else if (keep(tag)) {
        output.add(tag);
      }
    }
    if (weight != null && block.isNotEmpty) {
      block[0] = '$weight${block[0]}';
      output.addAll(block);
    }
    return output.join(', ');
  }

  static String positive(String prefix, String prompt) => cleanTags(prefix, {'no text', if (isMultiple(prompt)) 'solo'});
  static String negative(String value) => cleanTags(value, {'text', 'comic', 'screentone', 'halftone', 'multiple views', 'speech bubble'});
}
