import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'src/bindings.dart' as native;

/// Desktop job: POSIX process group/guardian or Windows kill-on-close Job.
/// Kept separate from either JS session; uses the existing native asset build.
class DesktopJob {
  DesktopJob._(this._job);
  final Pointer<Void> _job;
  bool _closed = false;

  /// Starts with inherited variables plus [environment], or the extras saved
  /// by [setEnvironment] when no explicit map is supplied.
  static DesktopJob start(
    String cwd,
    String command, {
    Map<String, String>? environment,
  }) {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw UnsupportedError('Desktop process required');
    }
    if (cwd.contains('\x00') || command.contains('\x00')) {
      throw ArgumentError('NUL in process arguments');
    }
    final extras = environment ?? _environment;
    _validateEnvironment(extras);
    final merged = <String, String>{};
    for (final entry in [...Platform.environment.entries, ...extras.entries]) {
      if (Platform.isWindows) {
        merged.removeWhere(
          (key, _) => key.toUpperCase() == entry.key.toUpperCase(),
        );
      }
      merged[entry.key] = entry.value;
    }
    final names = merged.keys.toList();
    if (Platform.isWindows) {
      names.sort((a, b) => a.toUpperCase().compareTo(b.toUpperCase()));
    }
    return using((arena) {
      final env = arena<Pointer<Char>>(names.length + 1);
      for (var i = 0; i < names.length; i++) {
        final name = names[i];
        env[i] = '$name=${merged[name]}'.toNativeUtf8(allocator: arena).cast();
      }
      env[names.length] = nullptr;
      final error = arena<Int32>();
      final job = native.processStart(
        cwd.toNativeUtf8(allocator: arena).cast(),
        (Platform.isWindows ? windowsCommandLine(command) : command)
            .toNativeUtf8(allocator: arena)
            .cast(),
        env,
        error,
      );
      if (job == nullptr) {
        throw ProcessException(
          Platform.isWindows ? 'powershell' : '/bin/sh',
          [
            if (Platform.isWindows) ...['-NoProfile', '-Command'] else '-c',
            command,
          ],
          Platform.isWindows ? 'CreateProcessW' : 'posix_spawn',
          error.value,
        );
      }
      return DesktopJob._(job);
    });
  }

  static Map<String, String> _environment = const {};

  /// Saves extra variables for subsequent jobs in this isolate. This never
  /// changes the app process environment; an explicit [start] map replaces it.
  static void setEnvironment(Map<String, String> variables) {
    _validateEnvironment(variables);
    _environment = Map.of(variables);
  }

  static void _validateEnvironment(Map<String, String> variables) {
    for (final entry in variables.entries) {
      final name = entry.key;
      if (name.isEmpty ||
          name.contains('=') ||
          name.contains('\x00') ||
          entry.value.contains('\x00')) {
        throw ArgumentError('Invalid environment variable: $name');
      }
    }
  }

  static String windowsCommandLine(String command) {
    // Windows CRT argument quoting, including quotes and trailing backslashes.
    final escaped = command
        .replaceAllMapped(RegExp(r'(\\*)"'), (m) => '${m[1]}${m[1]}\\"')
        .replaceAllMapped(RegExp(r'\\+$'), (m) => '${m[0]}${m[0]}');
    return 'powershell -NoProfile -Command "$escaped"';
  }

  int get pid => native.processPid(_job);
  int? get exitCode {
    final status = native.processStatus(_job);
    return status == -9223372036854775808 ? null : status;
  }

  /// null means EOF; an empty chunk means not ready yet.
  Uint8List? read() => using((arena) {
    final buffer = arena<Uint8>(65536);
    final size = native.processRead(_job, buffer, 65536);
    if (size == -2) return Uint8List(0);
    if (size < 0) throw const FileSystemException('Cannot read process output');
    return size == 0 ? null : Uint8List.fromList(buffer.asTypedList(size));
  });
  void kill() {
    if (!_closed) native.processKill(_job);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    native.processFree(_job);
  }
}

/// Separate open-file-description locks work across connections AND isolates.
class DesktopFileLock {
  DesktopFileLock._(this._handle);
  final Pointer<Void> _handle;
  bool _closed = false;
  static DesktopFileLock? tryOpen(String path) => using((arena) {
    final handle = native.processLock(
      path.toNativeUtf8(allocator: arena).cast(),
    );
    return handle == nullptr ? null : DesktopFileLock._(handle);
  });
  void close() {
    if (!_closed) {
      _closed = true;
      native.processUnlock(_handle);
    }
  }
}
