import 'package:characters/characters.dart';

const int _kToolHintMaxChars = 40;
const int _kPathHintMaxChars = 24;

/// Argument keys worth showing next to a tool name, most telling first.
const _kToolHintKeys = [
  'command',
  'path',
  'url',
  'query',
  'pattern',
  'name',
  'prompt',
];

/// The first line of the most telling argument, cut to a title-friendly
/// length. A long path keeps its last two segments, where the file name is.
String? toolCallHint(Map<String, dynamic>? arguments) {
  for (final key in _kToolHintKeys) {
    final value = arguments?[key];
    if (value is! String || value.trim().isEmpty) continue;
    var line = value.trim().split('\n').first;
    if (key == 'path') return _pathHint(line);
    final chars = line.characters;
    return chars.length > _kToolHintMaxChars
        ? '${chars.take(_kToolHintMaxChars)}…'
        : line;
  }
  return null;
}

String _pathHint(String path) {
  final trimmed = path.replaceFirst(RegExp(r'[/\\]+$'), '');
  final line = trimmed.isEmpty ? path : trimmed;
  if (line.characters.length <= _kPathHintMaxChars) return line;
  final segments = line
      .split(RegExp(r'[/\\]'))
      .where((s) => s.isNotEmpty)
      .toList();
  final fileName = segments.last;
  final fileChars = fileName.characters;
  if (fileChars.length > _kToolHintMaxChars) {
    // Keep both the recognizable name and its suffix/extension.
    return '${fileChars.take(25)}…${fileChars.takeLast(14)}';
  }
  final tail = segments.length > 2
      ? '…/${segments.sublist(segments.length - 2).join('/')}'
      : line;
  if (tail.characters.length <= _kToolHintMaxChars) return tail;

  final parentBudget = _kToolHintMaxChars - fileChars.length - 3;
  if (parentBudget < 2) {
    return fileChars.length + 2 <= _kToolHintMaxChars
        ? '…/$fileName'
        : fileName;
  }
  final parent = segments[segments.length - 2].characters;
  return '…/${parent.take(parentBudget - 1)}…/$fileName';
}

/// A tool name with its most telling argument, e.g. `read · /tmp/a.json`.
/// A codemode script reads as running a script; its nested calls report
/// themselves.
String toolCallLabel(String name, Map<String, dynamic>? arguments) {
  if (name == 'codemode') return '运行脚本';
  final hint = toolCallHint(arguments);
  return hint == null ? name : '$name · $hint';
}
