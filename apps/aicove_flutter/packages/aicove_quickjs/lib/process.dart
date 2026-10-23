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
  static DesktopJob start(String cwd, String command) {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw UnsupportedError('Desktop process required');
    }
    if (cwd.contains('\x00') || command.contains('\x00')) {
      throw ArgumentError('NUL in process arguments');
    }
    return using((arena) {
      final error = arena<Int32>();
      final job = native.processStart(
        cwd.toNativeUtf8(allocator: arena).cast(),
        (Platform.isWindows ? windowsCommandLine(command) : command)
            .toNativeUtf8(allocator: arena)
            .cast(),
        error,
      );
      if (job == nullptr) {
        throw ProcessException(
          '/bin/sh',
          ['-c', command],
          'posix_spawn',
          error.value,
        );
      }
      return DesktopJob._(job);
    });
  }

  static final _setNames = <String>{};

  /// Makes [variables] the extra environment of jobs started afterwards;
  /// names set by an earlier call and missing now are removed. Jobs inherit
  /// the app process environment, so call this right before [start].
  static void setEnvironment(Map<String, String> variables) {
    final names = {..._setNames, ...variables.keys};
    using((arena) {
      for (final name in names) {
        final value = variables[name];
        if (name.isEmpty || name.contains('=') || name.contains('\x00') ||
            (value?.contains('\x00') ?? false)) {
          throw ArgumentError('Invalid environment variable: $name');
        }
        if (Platform.isWindows) {
          final ok = _setEnvW(
            name.toNativeUtf16(allocator: arena),
            value == null ? nullptr : value.toNativeUtf16(allocator: arena),
          );
          if (ok == 0) throw StateError('Cannot set environment: $name');
        } else {
          final rc = value == null
              ? _unsetEnv(name.toNativeUtf8(allocator: arena))
              : _setEnv(
                  name.toNativeUtf8(allocator: arena),
                  value.toNativeUtf8(allocator: arena),
                  1,
                );
          if (rc != 0) throw StateError('Cannot set environment: $name');
        }
      }
    });
    _setNames
      ..clear()
      ..addAll(variables.keys);
  }

  static final _setEnv = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('setenv');
  static final _unsetEnv = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('unsetenv');
  static final _setEnvW = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)
      >('SetEnvironmentVariableW');

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
