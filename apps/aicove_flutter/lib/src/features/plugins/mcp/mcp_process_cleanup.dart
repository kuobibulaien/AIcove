import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// System helpers are separate from the MCP subprocess and never run user code.
/// Timeout kills the helper itself, rather than just abandoning its Future.
Future<ProcessResult?> runMcpProcessHelper(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  Process? process;
  var timedOut = false;
  final work = () async {
    final started = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    process = started;
    if (timedOut) started.kill();
    final output = started.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = started.stderr.drain<void>();
    final code = await started.exitCode;
    await errors;
    return ProcessResult(started.pid, code, await output, '');
  }();
  try {
    return await work.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    process?.kill();
    return null;
  } on ProcessException {
    return null;
  }
}

typedef McpProcessHelper =
    Future<ProcessResult?> Function(String executable, List<String> arguments);

/// PowerShell emits one object for one process, an array for several, and no
/// output for an empty result. Only numeric process/parent IDs are accepted.
Map<int, int> parseMcpWindowsProcessParents(String text) {
  if (text.trim().isEmpty) return {};
  final value = jsonDecode(text);
  final records = value is List ? value : [value];
  return {
    for (final record in records)
      if (record is Map &&
          record['ProcessId'] is int &&
          (record['ProcessId'] as int) > 0 &&
          record['ParentProcessId'] is int &&
          (record['ParentProcessId'] as int) >= 0)
        record['ProcessId'] as int: record['ParentProcessId'] as int,
  };
}

/// Root is never included, even if malformed records contain a cycle.
List<int> mcpDescendantPids(int root, Map<int, int> parents) {
  if (root <= 0) return [];
  final children = <int, List<int>>{};
  for (final entry in parents.entries) {
    if (entry.key > 0) (children[entry.value] ??= []).add(entry.key);
  }
  final visited = <int>{root};
  final found = <int>[];
  void visit(int parent) {
    for (final child in children[parent] ?? <int>[]) {
      if (!visited.add(child)) continue;
      found.add(child);
      visit(child);
    }
  }

  visit(root);
  return found;
}

String _windowsSystemTool(String suffix) =>
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\$suffix';

/// Capture before stdin closes: wrappers can exit and reparent their children.
/// Null means enumeration failed, distinct from a successful empty snapshot.
Future<List<int>?> captureMcpDescendants(
  int root, {
  bool? windows,
  McpProcessHelper? run,
}) async {
  final isWindows = windows ?? Platform.isWindows;
  final helper = run ?? runMcpProcessHelper;
  try {
    final result = await helper(
      isWindows
          ? _windowsSystemTool(r'WindowsPowerShell\v1.0\powershell.exe')
          : '/bin/ps',
      isWindows
          ? const [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              'Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId | ConvertTo-Json -Compress',
            ]
          : const ['-axo', 'pid=,ppid='],
    );
    if (result == null || result.exitCode != 0) return null;
    final parents = isWindows
        ? parseMcpWindowsProcessParents(result.stdout as String)
        : <int, int>{};
    if (!isWindows) {
      for (final line in (result.stdout as String).split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 2) continue;
        final pid = int.tryParse(parts[0]), parent = int.tryParse(parts[1]);
        if (pid != null && parent != null) parents[pid] = parent;
      }
    }
    return mcpDescendantPids(root, parents);
  } on FormatException {
    return null;
  }
}

/// A single bounded taskkill invocation includes captured children even when the
/// wrapper has already exited. Nonzero exits also take the Dart kill fallback.
Future<void> stopMcpWindowsProcesses(
  List<int> descendants, {
  int? parentPid,
  McpProcessHelper? run,
  bool Function(int)? kill,
}) async {
  final pids = {
    ...descendants.reversed.where((pid) => pid > 0),
    if (parentPid != null && parentPid > 0) parentPid,
  };
  if (pids.isEmpty) return;
  final result = await (run ?? runMcpProcessHelper)(
    _windowsSystemTool('taskkill.exe'),
    [
      '/T',
      '/F',
      for (final pid in pids) ...['/PID', '$pid'],
    ],
  );
  if (result == null || result.exitCode != 0) {
    for (final pid in pids) {
      (kill ?? Process.killPid)(pid);
    }
  }
}
