import 'dart:async';
import 'dart:convert';
import 'package:aicove_quickjs/process.dart';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show GateOutcome, ToolCallScope;
import '../../plugins/domain/handlers/ai_tool.dart';
import '../data/workspace_store.dart';
import 'workspace_script.dart';

/// Desktop command adapter authorized by the shared run tool gate.
class WorkspaceShell {
  WorkspaceShell({
    required this.store,
    required this.workspace,
    required this.runId,
    this.isCancelled,
    this.environment,
  });
  final WorkspaceStore store;
  final String workspace, runId;
  final bool Function()? isCancelled;

  /// Extra variables of this command, such as channel keys (ADR0109).
  final Map<String, String> Function()? environment;
  static const Duration? defaultTimeout = null;
  static const outputSchema = <String, dynamic>{
    'type': 'object',
    'properties': {
      'output': {'type': 'string'},
      'truncated': {'type': 'boolean'},
      'full_output_path': {'type': 'string'},
      'exit_code': {
        'type': ['integer', 'null'],
      },
      'wall_time_seconds': {'type': 'number'},
    },
    'required': ['output', 'truncated', 'exit_code', 'wall_time_seconds'],
  };
  static const settleTimeout = Duration(seconds: 5);

  static bool settleBudgetExhausted(Duration elapsed) =>
      elapsed >= settleTimeout;

  static bool available({required String platform}) =>
      ['macos', 'windows', 'linux'].contains(platform);

  static (String, List<String>) commandLine(String platform, String command) =>
      platform == 'windows'
      ? ('powershell', ['-NoProfile', '-Command', command])
      : ('/bin/sh', ['-c', command]);

  static Duration? deadline(Object? seconds) {
    if (seconds == null) return defaultTimeout;
    if (seconds is! int || seconds < 1) {
      throw ArgumentError('Shell deadline must be a positive integer');
    }
    return Duration(seconds: seconds);
  }

  Future<ToolOutput> run(
    String command, {
    Duration? timeout = defaultTimeout,
  }) async {
    // Runs without confirmation (ADR0106), but only through the run's gate.
    final scope = ToolCallScope.current;
    if (scope?.outcome != GateOutcome.allowed &&
        (scope?.outcome != GateOutcome.approved ||
            !(scope?.humanApproved ?? false))) {
      return const ToolOutput(
        text: 'Shell requires authorization by the tool policy.',
        isError: true,
      );
    }
    if ((timeout != null && timeout <= Duration.zero) ||
        command.contains('\x00')) {
      return const ToolOutput(
        text: 'Invalid shell deadline or command.',
        isError: true,
      );
    }
    final watch = Stopwatch()..start();
    final output = WorkspaceScriptOutput();
    WorkspaceCommandLease? lease;
    int? exit;
    String? error;
    var settled = true;
    try {
      if (isCancelled?.call() ?? false) throw StateError('Command cancelled');
      lease = await store.beginCommand(workspace, runId);
      if ((isCancelled?.call() ?? false) ||
          (timeout != null && watch.elapsed >= timeout)) {
        throw StateError(
          'Command cancelled or deadline exceeded before launch',
        );
      }
      final result = await _native(command, output, watch, timeout);
      exit = result.$1;
      error = result.$2;
      settled = result.$3;
    } on Object catch (failure) {
      error = '$failure';
    } finally {
      if (lease != null) {
        if (settled) {
          try {
            final scan = await store.finishCommand(lease);
            if (scan.unindexed.isNotEmpty) {
              error =
                  '${error == null ? '' : '$error\n'}Cannot index unsafe paths: ${scan.unindexed.join(', ')}';
            }
          } on Object catch (failure) {
            error =
                '${error == null ? '' : '$error\n'}Metadata restore/rescan failed; workspace remains locked for recovery: $failure';
          }
        } else {
          await lease.releaseForRecovery();
          error =
              '$error\nProcess did not settle in 5 seconds; workspace remains locked for recovery.';
        }
      }
    }
    final stdout = utf8.decode(output.fileBytes);
    String? fullPath;
    output.add(
      '\nexit_code: ${exit ?? 'unavailable'}; elapsed_ms: ${watch.elapsedMilliseconds}',
    );
    if (error != null) output.add(error);
    var text = output.modelText;
    if (output.truncated) {
      final path = WorkspaceScriptOutput.artifactPath(runId);
      try {
        await store.write(
          workspace,
          path,
          output.fileBytes,
          runId: hostRunId,
          allowHost: true,
        );
        fullPath = path;
        text +=
            '\nOutput truncated; ${output.fileTruncated ? 'only the last 8 MiB retained; ' : ''}full output: $path';
      } on Object catch (failure) {
        error = 'Cannot save shell output: $failure';
        text += '\n$error';
      }
    }
    return ToolOutput(
      text: WorkspaceScriptOutput.modelTail(text).trimRight(),
      isError: error != null,
      structured: {
        'output': stdout,
        'truncated': output.truncated,
        if (fullPath != null) 'full_output_path': fullPath,
        'exit_code': exit,
        'wall_time_seconds': watch.elapsedMicroseconds / 1000000,
      },
    );
  }

  String? _stop(Stopwatch watch, Duration? timeout) =>
      isCancelled?.call() ?? false
      ? 'Command cancelled'
      : (timeout != null && watch.elapsed >= timeout)
      ? 'Command timed out'
      : null;

  Future<(int?, String?, bool)> _native(
    String command,
    WorkspaceScriptOutput output,
    Stopwatch watch,
    Duration? timeout,
  ) async {
    // No await in between: concurrent shells cannot see another's variables.
    DesktopJob.setEnvironment(environment?.call() ?? const {});
    final job = DesktopJob.start(store.directoryOf(workspace).path, command);
    final decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_OutputSink(output));
    final cleanup = Stopwatch();
    String? stop;
    int? exit;
    var eof = false;
    try {
      while (true) {
        // Drain a bounded batch, so a busy writer cannot starve cancellation.
        for (var n = 0; n < 16 && !eof; n++) {
          final bytes = job.read();
          if (bytes == null) {
            eof = true;
            break;
          }
          if (bytes.isEmpty) break;
          decoder.add(bytes);
        }
        exit ??= job.exitCode;
        if (stop == null && (stop = _stop(watch, timeout)) != null) {
          job.kill();
          cleanup.start();
        }
        if (exit != null) {
          // Even a successful shell may leave background children behind.
          job.kill();
          if (!cleanup.isRunning) cleanup.start();
          if (eof) return (exit, stop, true);
        }
        if (cleanup.isRunning && settleBudgetExhausted(cleanup.elapsed)) {
          return (exit, stop, false);
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      job.kill();
      job.close();
      decoder.close();
    }
  }
}

class _OutputSink extends StringConversionSinkBase {
  _OutputSink(this.output);
  final WorkspaceScriptOutput output;
  @override
  void add(String chunk) => output.addChunk(chunk);
  @override
  void addSlice(String chunk, int start, int end, bool isLast) {
    add(chunk.substring(start, end));
    if (isLast) close();
  }

  @override
  void close() {}
}
