import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'src/bindings.dart' as native;

part 'src/async_session.dart';

class QuickJsException implements Exception {
  final String message;
  const QuickJsException(this.message);
  @override
  String toString() => 'QuickJsException: $message';
}

class QuickJsSync {
  static String evaluate(String source) {
    final runtime = native.create();
    if (runtime == nullptr)
      throw const QuickJsException('Cannot create runtime');
    final input = source.toNativeUtf8();
    try {
      final result = native.evaluate(
        runtime,
        input.cast(),
        utf8.encode(source).length,
      );
      if (result == nullptr)
        throw const QuickJsException('Native evaluation failed');
      try {
        final text = result.cast<Utf8>().toDartString();
        if (native.failed(runtime) != 0) throw QuickJsException(text);
        return text;
      } finally {
        native.freeText(result);
      }
    } finally {
      malloc.free(input);
      native.destroy(runtime);
    }
  }
}

class QuickJsSession {
  static const maxBytes = 8 * 1024 * 1024;
  final SendPort _commands;
  final Pointer<Void> _flag;
  final QuickJsHostCall? _hostCall;
  final int _maxSourceBytes;
  final Duration _timeout;
  final bool Function()? _isCancelled;
  final void Function(String)? _onText;
  bool _closed = false;
  Future<void> _tail = Future.value();
  QuickJsSession._(
    this._commands,
    this._flag,
    this._hostCall,
    this._maxSourceBytes,
    this._timeout,
    this._isCancelled,
    this._onText,
  );

  static Future<QuickJsSession> open({
    QuickJsHostCall? hostCall,
    int heapBytes = 64 * 1024 * 1024,
    int maxSourceBytes = maxBytes,
    Duration timeout = const Duration(milliseconds: 1000),
    bool Function()? isCancelled,
    void Function(String)? onText,
  }) async {
    if (heapBytes <= 0 ||
        maxSourceBytes <= 0 ||
        timeout <= Duration.zero ||
        timeout.inMilliseconds == 0)
      throw const QuickJsException('Invalid session limits');
    final flag = native.cancelNew();
    if (flag == nullptr)
      throw const QuickJsException('Native allocation failed');
    final ready = ReceivePort();
    try {
      await Isolate.spawn(_sessionWorker, [
        ready.sendPort,
        flag.address,
        heapBytes,
        timeout.inMilliseconds,
        hostCall != null,
      ]);
      final port = await ready.first;
      if (port is! SendPort) throw QuickJsException('$port');
      return QuickJsSession._(
        port,
        flag,
        hostCall,
        maxSourceBytes,
        timeout,
        isCancelled,
        onText,
      );
    } catch (_) {
      native.cancelFree(flag);
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<String> evaluate(String source) {
    final result = Completer<String>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await _evaluate(source));
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<String> _evaluate(String source) async {
    if (_closed) throw const QuickJsException('QuickJS session is closed');
    if (utf8.encode(source).length > _maxSourceBytes)
      throw const QuickJsException('Input exceeds source limit');
    if (_isCancelled?.call() ?? false) {
      await close();
      throw const QuickJsException('Invocation cancelled');
    }
    final events = ReceivePort();
    var active = true;
    final queue = <List>[];
    var running = 0;
    late void Function() drain;
    drain = () {
      while (active &&
          running < QuickJsAsyncSession.maxHostCalls &&
          queue.isNotEmpty) {
        final call = queue.removeAt(0);
        running++;
        () async {
          Object? value;
          var ok = true;
          try {
            value = await _hostCall!(
              call[1] as String,
              call[2] as List,
              () => active && !_closed,
            );
          } catch (e) {
            ok = false;
            value = '$e';
          }
          if (active && !_closed)
            _commands.send([
              'deliver',
              jsonEncode([call[0], ok, value]),
            ]);
          running--;
          drain();
        }();
      }
    };
    final deadline = Timer(_timeout, () {
      native.cancelSet(_flag);
      _commands.send(['interrupt']);
    });
    final cancelTimer = _isCancelled == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 5), (_) {
            if (_isCancelled()) {
              native.cancelSet(_flag);
              _commands.send(['interrupt']);
            }
          });
    _commands.send(['evaluate', source, events.sendPort]);
    try {
      await for (final dynamic event in events) {
        final data = event as List;
        switch (data[0]) {
          case 'text':
            for (final text in data[1] as List) {
              _onText?.call(text as String);
            }
          case 'calls':
            queue.addAll((data[1] as List).cast<List>());
            drain();
          case 'done':
            if (data[1] == 1) {
              final value = data[2] as String;
              if (utf8.encode(value).length > _maxSourceBytes) {
                await close();
                throw const QuickJsException(
                  'JavaScript output limit or conversion failure',
                );
              }
              return value;
            }
            final error = data[2] as String;
            await close();
            throw QuickJsException(error);
        }
      }
      throw const QuickJsException('QuickJS session is closed');
    } finally {
      active = false;
      deadline.cancel();
      cancelTimer?.cancel();
      events.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    native.cancelSet(_flag);
    final reply = ReceivePort();
    _commands.send(['close', reply.sendPort]);
    await reply.first;
    reply.close();
    native.cancelFree(_flag);
  }
}

void _sessionWorker(List args) {
  final ready = args[0] as SendPort;
  final runtime = native.asyncCreate(
    Pointer<Void>.fromAddress(args[1] as int),
    args[2] as int,
    args[3] as int,
  );
  if (runtime == nullptr) {
    ready.send('Cannot create runtime');
    return;
  }
  void begin(String source) {
    final input = source.toNativeUtf8();
    try {
      native.asyncBegin(runtime, input.cast(), utf8.encode(source).length);
    } finally {
      malloc.free(input);
    }
  }

  begin(
    '${args[4] ? '' : "Object.defineProperty(globalThis, '__aq_no_host', {value: true});"}\n$_asyncBootstrap',
  );
  if (native.asyncStep(runtime) != 1) {
    final error = _asyncText(native.asyncResult(runtime));
    native.asyncDestroy(runtime);
    ready.send(error);
    return;
  }
  final commands = ReceivePort();
  SendPort? events;
  var closed = false;
  void pump() {
    if (closed || events == null) return;
    try {
      final state = native.asyncStep(runtime);
      var pending = 0;
      if (state != -2) {
        final pointer = native.asyncTake(runtime);
        if (pointer == nullptr)
          throw const QuickJsException(
            'Native allocation or conversion failed',
          );
        final packet = jsonDecode(_asyncText(pointer)) as Map;
        pending = packet['pending'] as int;
        if ((packet['text'] as List).isNotEmpty)
          events!.send(['text', packet['text']]);
        if ((packet['calls'] as List).isNotEmpty)
          events!.send(['calls', packet['calls']]);
      }
      if (state == 2) {
        Timer.run(pump);
        return;
      }
      if (state == 0 && pending > 0) return;
      final value = state == 0
          ? 'Unresolved async operation: host I/O is unavailable'
          : state == -2
          ? 'JavaScript interrupted'
          : _asyncText(native.asyncResult(runtime));
      events!.send(['done', state == 0 ? -1 : state, value]);
      events = null;
    } catch (e) {
      events?.send(['done', -1, '$e']);
      events = null;
    }
  }

  commands.listen((dynamic message) {
    final data = message as List;
    switch (data[0]) {
      case 'evaluate':
        events = data[2] as SendPort;
        begin(data[1] as String);
        pump();
      case 'deliver':
        if (events == null) return;
        final json = data[1] as String;
        final input = json.toNativeUtf8();
        try {
          native.asyncDeliver(runtime, input.cast(), utf8.encode(json).length);
        } finally {
          malloc.free(input);
        }
        pump();
      case 'interrupt':
        pump();
      case 'close':
        events?.send(['done', -1, 'QuickJS session is closed']);
        events = null;
        closed = true;
        native.asyncDestroy(runtime);
        (data[1] as SendPort).send(true);
        commands.close();
    }
  });
  ready.send(commands.sendPort);
}
