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

  static String cleanTags(String input, Set<String> remove) => input.split(RegExp(r'[,，\n]+')).map((tag) => tag.trim()).where((tag) {
    var normalized = tag.toLowerCase().trim();
    while (true) {
      final previous = normalized;
      normalized = normalized.replaceFirst(RegExp(r'^[-+]?\d*\.?\d+\s*::\s*'), '').replaceFirst(RegExp(r'\s*::$'), '').trim();
      if (normalized.length >= 2 &&
          ((normalized.startsWith('(') && normalized.endsWith(')')) ||
           (normalized.startsWith('{') && normalized.endsWith('}')) ||
           (normalized.startsWith('[') && normalized.endsWith(']')))) {
        normalized = normalized.substring(1, normalized.length - 1).trim();
      }
      if (normalized == previous) break;
    }
    return tag.isNotEmpty && !remove.contains(normalized);
  }).join(', ');

  static String positive(String prefix, String prompt) => cleanTags(prefix, {'no text', if (isMultiple(prompt)) 'solo'});
  static String negative(String value) => cleanTags(value, {'text', 'comic', 'screentone', 'halftone', 'multiple views', 'speech bubble'});
}
