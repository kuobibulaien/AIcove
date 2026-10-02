import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'src/bindings.dart' as native;

class QuickJsException implements Exception {
  final String message;
  const QuickJsException(this.message);
  @override
  String toString() => 'QuickJsException: $message';
}

/// One bounded runtime owned by a worker isolate. No network or host I/O.
/// This isolates JS state and UI scheduling, not native memory faults.
class QuickJsSession {
  final SendPort _commands;
  bool _closed = false;
  QuickJsSession._(this._commands);

  static Future<QuickJsSession> open() async {
    final reply = ReceivePort();
    await Isolate.spawn(_worker, reply.sendPort);
    final result = await reply.first;
    reply.close();
    if (result is! SendPort) throw QuickJsException('$result');
    return QuickJsSession._(result);
  }

  Future<String> evaluate(String source) async {
    if (_closed) throw const QuickJsException('Session closed');
    if (utf8.encode(source).length > 8 * 1024 * 1024) {
      throw const QuickJsException('Input exceeds 8 MiB');
    }
    final reply = ReceivePort();
    _commands.send([source, reply.sendPort]);
    try {
      final value = await reply.first as List;
      if (value[0] != true) {
        await close();
        throw QuickJsException(value[1] as String);
      }
      return value[1] as String;
    } finally {
      reply.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final reply = ReceivePort();
    _commands.send([null, reply.sendPort]);
    await reply.first;
    reply.close();
  }
}

void _worker(SendPort ready) {
  Pointer<Void> runtime;
  try {
    runtime = native.create();
    if (runtime == nullptr) {
      throw const QuickJsException('Cannot create runtime');
    }
  } catch (error) {
    ready.send('$error');
    return;
  }
  final commands = ReceivePort();
  ready.send(commands.sendPort);
  commands.listen((dynamic data) {
    final request = data as List;
    final reply = request[1] as SendPort;
    if (request[0] == null) {
      native.destroy(runtime);
      reply.send(true);
      commands.close();
      return;
    }
    final source = request[0] as String;
    final input = source.toNativeUtf8();
    Pointer<Char> output = nullptr;
    try {
      output = native.evaluate(
        runtime,
        input.cast(),
        utf8.encode(source).length,
      );
      if (output == nullptr) {
        throw const QuickJsException('Native allocation failed');
      }
      reply.send([
        native.failed(runtime) == 0,
        output.cast<Utf8>().toDartString(),
      ]);
    } catch (error) {
      reply.send([false, '$error']);
    } finally {
      if (output != nullptr) native.freeText(output);
      malloc.free(input);
    }
  });
}
