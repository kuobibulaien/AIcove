import 'dart:io';

import '../../../core/utils/desktop_process_environment.dart';

/// Backslashes in Windows
/// paths remain literal; before a quote they follow Windows argv escaping rules.
List<String> parseMcpCommandLine(String line) {
  final words = <String>[];
  var word = StringBuffer();
  String? quote;
  var started = false;
  var needsShell = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '\\' && quote != "'") {
      var count = 1;
      while (i + count < line.length && line[i + count] == '\\') {
        count++;
      }
      if (i + count < line.length && line[i + count] == '"') {
        word.write('\\' * (count ~/ 2));
        if (count.isOdd) {
          word.write('"');
        } else {
          quote = quote == '"' ? null : '"';
        }
        started = true;
        i += count;
      } else if (quote == null &&
          count == 1 &&
          i + 1 < line.length &&
          (RegExp(r'\s').hasMatch(line[i + 1]) || line[i + 1] == "'")) {
        word.write(line[++i]);
        started = true;
      } else {
        word.write('\\' * count);
        started = true;
        i += count - 1;
      }
      continue;
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        word.write(c);
      }
      started = true;
    } else if (c == '"' || c == "'") {
      quote = c;
      started = true;
    } else if (RegExp(r'\s').hasMatch(c)) {
      if (started) words.add(word.toString());
      word = StringBuffer();
      started = false;
    } else {
      if ('|&;<>`'.contains(c)) needsShell = true;
      word.write(c);
      started = true;
    }
  }
  if (quote != null) throw const FormatException('引号未闭合');
  if (started) words.add(word.toString());
  if (words.isEmpty || words.first.isEmpty) {
    throw const FormatException('请填写启动命令');
  }
  if (needsShell) {
    return Platform.isWindows
        ? ['cmd.exe', '/d', '/s', '/c', line.trim()]
        : ['/bin/sh', '-c', line.trim()];
  }
  return words;
}

List<String> expandMcpCommandVariables(
  List<String> args,
  Map<String, String> env,
) => [
  for (final arg in args)
    arg.replaceAllMapped(
      RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)'),
      (m) => env[m[1] ?? m[2]] ?? '',
    ),
];

class McpStdioLaunch {
  const McpStdioLaunch(this.command, this.args, {this.runInShell = false});
  final String command;
  final List<String> args;
  final bool runInShell;
}

McpStdioLaunch resolveMcpStdioLaunch(
  String command,
  List<String> args,
  Map<String, String> env, {
  String? cwd,
}) {
  final shell =
      (command == '/bin/sh' && args.length >= 2 && args.first == '-c') ||
      (command.toLowerCase() == 'cmd.exe' &&
          args.length >= 4 &&
          args[2] == '/c');
  final expanded = shell
      ? [command, ...args]
      : expandMcpCommandVariables([command, ...args], env);
  final executable = resolveMcpExecutable(expanded.first, env, cwd: cwd);
  return McpStdioLaunch(
    executable,
    expanded.skip(1).toList(),
    runInShell:
        Platform.isWindows &&
        RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(executable),
  );
}

String formatMcpCommandLine(String command, List<String> args) {
  if (command.isEmpty && args.isEmpty) return '';
  return [command, ...args]
      .map((word) {
        if (word.isNotEmpty && !RegExp(r'''[\s'"|&;<>`$]''').hasMatch(word)) {
          return word;
        }
        // Adjacent quoted segments preserve apostrophes and literal shell symbols.
        return "'${word.replaceAll("'", "'\"'\"'")}'";
      })
      .join(' ');
}

Map<String, String> parseMcpEnvironment(String text) {
  final result = <String, String>{};
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final equals = line.indexOf('=');
    final key = equals < 0 ? '' : line.substring(0, equals).trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
      throw const FormatException('环境变量请按每行 KEY=VALUE 填写');
    }
    result[key] = line.substring(equals + 1);
  }
  return result;
}

String expandMcpHome(String value, String? home) =>
    expandDesktopHome(value, home);

/// Kept as the MCP entry point; desktop shell launches share the same PATH.
Map<String, String> mcpProcessEnvironment({
  Map<String, String>? parent,
  Map<String, String> overrides = const {},
}) => desktopProcessEnvironment(parent: parent, overrides: overrides);

/// Resolve against the merged PATH explicitly: Process.start's executable lookup
/// can use the parent's PATH instead of the supplied child environment.
String resolveMcpExecutable(
  String command,
  Map<String, String> env, {
  String? cwd,
}) {
  final expanded = expandMcpHome(command, env['HOME'] ?? env['USERPROFILE']);
  final candidates = expanded.contains('/') || expanded.contains('\\')
      ? [
          File(expanded).isAbsolute
              ? expanded
              : '${cwd ?? Directory.current.path}/$expanded',
        ]
      : [
          for (final path in (env['PATH'] ?? '').split(
            Platform.isWindows ? ';' : ':',
          ))
            if (path.isNotEmpty) '$path/$expanded',
        ];
  final extensions = Platform.isWindows
      ? (env['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD').split(';')
      : <String>[];
  for (final candidate in candidates) {
    for (final path in [
      candidate,
      if (Platform.isWindows) ...extensions.map((e) => '$candidate$e'),
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      if (Platform.isWindows &&
          !RegExp(
            r'\.(exe|com|cmd|bat)$',
            caseSensitive: false,
          ).hasMatch(path)) {
        continue;
      }
      if (!Platform.isWindows && file.statSync().mode & 0x49 == 0) continue;
      return file.absolute.path;
    }
  }
  throw const ProcessException('', [], '找不到启动程序，请检查命令或环境变量 PATH');
}
