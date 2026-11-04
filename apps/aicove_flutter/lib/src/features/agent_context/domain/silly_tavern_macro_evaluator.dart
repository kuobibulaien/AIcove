library;

import '../../conversation_state/domain/mvu_content.dart';

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
  static const int maxEvaluations = 50000;

  const SillyTavernMacroEvaluator();

  SillyTavernMacroEvaluationResult evaluate(
    String source, {
    required String promptId,
    required Map<String, String> values,
    required Map<String, String> variables,
    required SillyTavernRandomIndexPicker randomIndexPicker,
    required List<String> warnings,
    Map<String, Object?>? messageVariables,
    bool escapeMacroValues = false,
    bool recursive = true,
  }) {
    final applied = <String>{};
    final unknown = <String>{};
    var output = source;
    var evaluations = 0;
    final innermostMacro = RegExp(r'\{\{([^{}]*)\}\}');

    for (var pass = 0; pass < (recursive ? maxPasses : 1); pass++) {
      final buffer = StringBuffer();
      var handled = false;
      var cursor = 0;
      var depthCursor = 0;
      var depth = 0;
      var evaluationLimitReached = false;
      var pending = output;

      while (true) {
        final matches = innermostMacro.allMatches(pending, cursor);
        if (matches.isEmpty) break;
        final match = matches.first;
        while (depthCursor < match.start) {
          if (pending.startsWith('{{', depthCursor)) {
            depth++;
            depthCursor += 2;
          } else if (pending.startsWith('}}', depthCursor)) {
            if (depth > 0) depth--;
            depthCursor += 2;
          } else {
            depthCursor++;
          }
        }
        buffer.write(pending.substring(cursor, match.start));
        cursor = match.start;
        if (evaluations >= maxEvaluations) {
          evaluationLimitReached = true;
          break;
        }
        evaluations++;
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
          messageVariables: messageVariables,
        );
        cursor = match.end;
        depthCursor = match.end;
        if (replacement.handled) handled = true;
        if (recursive && !escapeMacroValues && replacement.handled && depth == 0 &&
            (replacement.text.contains('{') || replacement.text.contains('}'))) {
          // Rescan only the replacement and unprocessed suffix, preserving
          // document order without spending another nesting pass.
          pending = replacement.text + pending.substring(cursor);
          cursor = 0;
          depthCursor = 0;
          continue;
        }
        buffer.write(replacement.handled && escapeMacroValues
            ? RegExp.escape(replacement.text)
            : replacement.text);
        if (recursive && replacement.handled && depth > 0) break;
      }
      buffer.write(pending.substring(cursor));
      output = buffer.toString();
      if (evaluationLimitReached) {
        warnings.add('$promptId 宏求值超过 $maxEvaluations 次，已停止继续展开');
        break;
      }
      if (!handled) break;
      if (pass == maxPasses - 1 &&
          innermostMacro.allMatches(output).any((match) => _evaluateMacro(
                (match.group(1) ?? '').trim(),
                rawMacro: match.group(0) ?? '',
                promptId: promptId,
                values: values,
                variables: Map.of(variables),
                randomIndexPicker: (_) => 0,
                warnings: [],
                applied: {},
                unknown: {},
                messageVariables: messageVariables,
              ).handled)) {
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
    Map<String, Object?>? messageVariables,
  }) {
    if (body.startsWith('//')) {
      applied.add('//');
      return const _MacroReplacement('', handled: true);
    }

    final roll = RegExp(r'^roll(?:\s+|::?)(.+)$', caseSensitive: false)
        .firstMatch(body);
    if (roll != null) {
      final dice = RegExp(r'^(?:(\d*)d)?(\d+)(?:\s*([+-])\s*(\d+))?$',
              caseSensitive: false)
          .firstMatch(roll[1]!.trim());
      if (dice != null) {
        final count = dice[1] == null
            ? 1
            : int.tryParse(dice[1]!.isEmpty ? '1' : dice[1]!);
        final sides = int.tryParse(dice[2]!);
        final adjustment = int.tryParse(dice[4] ?? '0');
        if (count != null && count > 0 &&
            sides != null && sides > 0 && adjustment != null) {
          var total = dice[3] == '-' ? -adjustment : adjustment;
          for (var i = 0; i < count; i++) {
            total += randomIndexPicker(sides) + 1;
          }
          applied.add('roll');
          return _MacroReplacement('$total', handled: true);
        }
      }
    }

    final parts = body.split('::');
    final name = parts.first.trim().toLowerCase();
    final directValue = values[name];
    if (directValue != null) {
      applied.add(name);
      return _MacroReplacement(directValue, handled: true);
    }

    switch (name) {
      case 'incvar':
      case 'decvar':
      case 'addvar':
        if (parts.length == (name == 'addvar' ? 3 : 2) &&
            parts[1].trim().isNotEmpty) {
          final key = parts[1].trim();
          final current = num.tryParse(variables[key] ?? '0');
          final delta = name == 'addvar'
              ? num.tryParse(parts[2].trim())
              : (name == 'incvar' ? 1 : -1);
          if (current != null && delta != null) {
            variables[key] = '${current + delta}';
            applied.add(name);
            return const _MacroReplacement('', handled: true);
          }
        }
        return _MacroReplacement(rawMacro, handled: false);
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
      case 'get_message_variable':
      case 'format_message_variable':
        // MVU 楼层变量（ADR0071）：只读请求固定的状态，不与 setvar/getvar 混用。
        if (messageVariables == null) {
          if (unknown.add(name)) {
            warnings.add('$promptId 使用了 MVU 变量宏，本会话未启用 MVU 变量，已保留 $rawMacro');
          }
          return _MacroReplacement(rawMacro, handled: false);
        }
        final path = parts.sublist(1).join('::').trim();
        final value = readMessageVariableMacro(
          messageVariables,
          path,
          yaml: name == 'format_message_variable',
        );
        if (value == null) {
          warnings.add('$promptId 的 $rawMacro 路径不存在，已替换为空文本');
        }
        applied.add(name);
        return _MacroReplacement(value ?? '', handled: true);
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
