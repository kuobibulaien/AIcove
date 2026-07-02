library;

class PromptTemplateRenderer {
  const PromptTemplateRenderer._();

  static final RegExp _placeholderPattern = RegExp(r'\{([a-zA-Z0-9_]+)\}');

  static String render(
    String template,
    Map<String, Object?> variables, {
    bool preserveUnknown = true,
  }) {
    if (template.isEmpty) return template;
    return template.replaceAllMapped(_placeholderPattern, (match) {
      final key = match.group(1) ?? '';
      if (key.isEmpty || !variables.containsKey(key)) {
        return preserveUnknown ? match.group(0)! : '';
      }
      final value = variables[key];
      if (value == null) {
        return preserveUnknown ? match.group(0)! : '';
      }
      return value.toString();
    });
  }

  static String renderTrimmed(
    String template,
    Map<String, Object?> variables, {
    bool preserveUnknown = true,
    bool collapseExtraBlankLines = false,
  }) {
    var rendered = render(
      template,
      variables,
      preserveUnknown: preserveUnknown,
    ).trim();
    if (collapseExtraBlankLines) {
      rendered = rendered.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    }
    return rendered;
  }

  static String prefixedBlock(
    String blockTemplate,
    Map<String, Object?> variables, {
    String prefix = '\n\n',
    bool preserveUnknown = true,
    bool collapseExtraBlankLines = false,
  }) {
    final rendered = renderTrimmed(
      blockTemplate,
      variables,
      preserveUnknown: preserveUnknown,
      collapseExtraBlankLines: collapseExtraBlankLines,
    );
    if (rendered.isEmpty) return '';
    return '$prefix$rendered';
  }

  static String prefixedText(
    String prefix,
    String text, {
    bool trim = true,
  }) {
    final normalized = trim ? text.trim() : text;
    if (normalized.isEmpty) return '';
    return '$prefix$normalized';
  }
}
