/// Ordered rules from the workspace root down to the current directory.
/// Paths and rule bases use forward slashes, relative to the same root.
class GitignoreMatcher {
  GitignoreMatcher([this._rules = const []]);

  final List<_IgnoreRule> _rules;

  GitignoreMatcher withRules(String content, {required String base}) {
    final rules = <_IgnoreRule>[..._rules];
    for (var line in content.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      // Unescaped trailing spaces are insignificant in gitignore files.
      while (line.endsWith(' ')) {
        var slashes = 0;
        for (var i = line.length - 2; i >= 0 && line[i] == r'\'; i--) {
          slashes++;
        }
        if (slashes.isOdd) break;
        line = line.substring(0, line.length - 1);
      }
      if (line.isEmpty || line.startsWith('#')) continue;
      final negated = line.startsWith('!');
      if (negated) line = line.substring(1);
      if (line.isEmpty) continue;
      final directoryOnly = line.endsWith('/');
      if (directoryOnly) line = line.substring(0, line.length - 1);
      final anchored = line.startsWith('/');
      if (anchored) line = line.substring(1);
      if (line.isEmpty) continue;
      final prefix = anchored || line.contains('/') ? '^' : r'(?:^|/)';
      try {
        rules.add(
          _IgnoreRule(
            base,
            RegExp('$prefix${_globRegex(line)}\$'),
            directoryOnly,
            negated,
          ),
        );
      } on FormatException {
        // Invalid character ranges do not match any path.
      }
    }
    return GitignoreMatcher(rules);
  }

  bool ignores(String path, {required bool isDirectory}) {
    var ignored = false;
    for (final rule in _rules) {
      if (rule.directoryOnly && !isDirectory) continue;
      if (rule.base.isNotEmpty && !path.startsWith('${rule.base}/')) continue;
      final local = rule.base.isEmpty
          ? path
          : path.substring(rule.base.length + 1);
      if (rule.pattern.hasMatch(local)) ignored = !rule.negated;
    }
    return ignored;
  }
}

class _IgnoreRule {
  const _IgnoreRule(this.base, this.pattern, this.directoryOnly, this.negated);
  final String base;
  final RegExp pattern;
  final bool directoryOnly;
  final bool negated;
}

String _globRegex(String pattern) {
  final out = StringBuffer();
  for (var i = 0; i < pattern.length; i++) {
    final char = pattern[i];
    if (char == r'\' && i + 1 < pattern.length) {
      out.write(RegExp.escape(pattern[++i]));
    } else if (char == '*') {
      final start = i;
      while (i + 1 < pattern.length && pattern[i + 1] == '*') {
        i++;
      }
      final atBoundary = start == 0 || pattern[start - 1] == '/';
      if (i > start && atBoundary && i + 1 == pattern.length) {
        out.write('.*');
      } else if (i > start && atBoundary && pattern[i + 1] == '/') {
        out.write('(?:[^/]+/)*');
        i++;
      } else {
        out.write('[^/]*');
      }
    } else if (char == '?') {
      out.write('[^/]');
    } else if (char == '[') {
      var end = i + 1;
      if (end < pattern.length && '!^'.contains(pattern[end])) end++;
      if (end < pattern.length && pattern[end] == ']') end++;
      while (end < pattern.length && pattern[end] != ']') {
        if (pattern[end] == r'\' && end + 1 < pattern.length) end++;
        end++;
      }
      if (end == pattern.length) {
        out.write(r'\[');
      } else {
        var body = pattern.substring(i + 1, end);
        if (body.startsWith('!')) body = '^${body.substring(1)}';
        final first = body.startsWith('^') ? 1 : 0;
        if (body[first] == ']') {
          body = '${body.substring(0, first)}\\${body.substring(first)}';
        }
        // A wildcard character class must never consume a path separator.
        out.write('(?!/)[$body]');
        i = end;
      }
    } else {
      out.write(RegExp.escape(char));
    }
  }
  return out.toString();
}
