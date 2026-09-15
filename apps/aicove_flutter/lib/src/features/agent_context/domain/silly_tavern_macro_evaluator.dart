library;

typedef SillyTavernRandomIndexPicker = int Function(int length);

class SillyTavernMacroEvaluationResult {
  final String text;
  final Set<String> appliedMacros;
  final Set<String> unknownMacros;

  const SillyTavernMacroEvaluationResult({
    required this.text,
    required this.appliedMacros,
    required this.unknownMacros,
  });
}

class _MacroReplacement {
  final String text;
  final bool handled;

  const _MacroReplacement(this.text, {required this.handled});
}

/// Evaluates the prompt macros used by SillyTavern Chat Completion presets.
///
/// Evaluation is intentionally stateful through [variables]: `setvar` updates
/// the supplied map and later prompts in the same recipe can immediately read
/// the value with `getvar`.
class SillyTavernMacroEvaluator {
  static const int maxPasses = 256;
  static const int maxExpandedCharacters = 2 * 1024 * 1024;

  const SillyTavernMacroEvaluator();

  SillyTavernMacroEvaluationResult evaluate(
    String source, {
    required String promptId,
    required Map<String, String> values,
    required Map<String, String> variables,
    required SillyTavernRandomIndexPicker randomIndexPicker,
    required List<String> warnings,
  }) {
    final applied = <String>{};
    final unknown = <String>{};
    var output = source;
    final innermostMacro = RegExp(r'\{\{([^{}]*)\}\}');

    for (var pass = 0; pass < maxPasses; pass++) {
      final matches = innermostMacro.allMatches(output).toList(growable: false);
      if (matches.isEmpty) break;

      var handled = false;
      for (final match in matches) {
        final rawMacro = match.group(0) ?? '';
        final body = (match.group(1) ?? '').trim();
        final replacement = _evaluateMacro(
          body,
          rawMacro: rawMacro,
          promptId: promptId,
          values: values,
          variables: variables,
          randomIndexPicker: randomIndexPicker,
          warnings: warnings,
          applied: applied,
          unknown: unknown,
        );
        if (!replacement.handled) continue;
        output =
            '${output.substring(0, match.start)}'
            '${replacement.text}'
            '${output.substring(match.end)}';
        handled = true;
        break;
      }
      if (!handled) break;
      if (output.length > maxExpandedCharacters) {
        warnings.add('$promptId 宏展开超过 2 MB，已停止继续求值');
        output = output.substring(0, maxExpandedCharacters);
        break;
      }
      if (pass == maxPasses - 1 && innermostMacro.hasMatch(output)) {
        warnings.add('$promptId 宏求值超过 $maxPasses 轮，已停止继续展开');
      }
    }

    // SillyTavern's legacy {{trim}} removes itself and every adjacent newline.
    output = output.replaceAll(
      RegExp(r'(?:\r?\n)*\{\{\s*trim\s*\}\}(?:\r?\n)*', caseSensitive: false),
      '',
    );

    return SillyTavernMacroEvaluationResult(
      text: output,
      appliedMacros: Set.unmodifiable(applied),
      unknownMacros: Set.unmodifiable(unknown),
    );
  }

  _MacroReplacement _evaluateMacro(
    String body, {
    required String rawMacro,
    required String promptId,
    required Map<String, String> values,
    required Map<String, String> variables,
    required SillyTavernRandomIndexPicker randomIndexPicker,
    required List<String> warnings,
    required Set<String> applied,
    required Set<String> unknown,
  }) {
    if (body.startsWith('//')) {
      applied.add('//');
      return const _MacroReplacement('', handled: true);
    }

    final parts = body.split('::');
    final name = parts.first.trim().toLowerCase();
    final directValue = values[name];
    if (directValue != null) {
      applied.add(name);
      return _MacroReplacement(directValue, handled: true);
    }

    switch (name) {
      case 'original':
        if (values.containsKey('original')) {
          applied.add(name);
          return _MacroReplacement(values['original'] ?? '', handled: true);
        }
        if (unknown.add(name)) {
          warnings.add('$promptId 没有外部 prompt override，已保留 {{original}}');
        }
        return _MacroReplacement(rawMacro, handled: false);
      case 'setvar':
        if (parts.length == 2 && parts[1].trim().endsWith(':')) {
          final key = parts[1].trim().substring(0, parts[1].trim().length - 1);
          if (key.isNotEmpty) {
            variables[key] = '';
            applied.add(name);
            warnings.add('$promptId 的 $rawMacro 少一个分隔冒号，已按空值 setvar 兼容');
            return const _MacroReplacement('', handled: true);
          }
        }
        if (parts.length < 3 || parts[1].trim().isEmpty) {
          if (unknown.add('setvar:invalid')) {
            warnings.add('$promptId 的 setvar 格式无效，已保留 $rawMacro');
          }
          return _MacroReplacement(rawMacro, handled: false);
        }
        final key = parts[1].trim();
        variables[key] = parts.sublist(2).join('::');
        applied.add(name);
        return const _MacroReplacement('', handled: true);
      case 'getvar':
        if (parts.length < 2 || parts.sublist(1).join('::').trim().isEmpty) {
          if (unknown.add('getvar:invalid')) {
            warnings.add('$promptId 的 getvar 格式无效，已保留 $rawMacro');
          }
          return _MacroReplacement(rawMacro, handled: false);
        }
        final key = parts.sublist(1).join('::').trim();
        applied.add(name);
        return _MacroReplacement(variables[key] ?? '', handled: true);
      case 'random':
      case 'pick':
        if (parts.length < 2) {
          warnings.add('$promptId 的 $name 没有候选项，已替换为空文本');
          applied.add(name);
          return const _MacroReplacement('', handled: true);
        }
        final candidates = parts.sublist(1);
        final selected = randomIndexPicker(candidates.length);
        final safeIndex = selected.clamp(0, candidates.length - 1);
        applied.add(name);
        return _MacroReplacement(candidates[safeIndex], handled: true);
      case 'trim':
        // Keep the marker until post-processing so surrounding newlines can be
        // removed exactly like SillyTavern.
        applied.add(name);
        return _MacroReplacement(rawMacro, handled: false);
      case 'newline':
        final count = parts.length > 1
            ? (int.tryParse(parts[1].trim()) ?? 1).clamp(0, 100)
            : 1;
        applied.add(name);
        return _MacroReplacement(
          List<String>.filled(count, '\n').join(),
          handled: true,
        );
      case 'noop':
        applied.add(name);
        return const _MacroReplacement('', handled: true);
      default:
        if (unknown.add(name)) {
          warnings.add('$promptId 保留了未支持的宏：$rawMacro');
        }
        return _MacroReplacement(rawMacro, handled: false);
    }
  }
}
