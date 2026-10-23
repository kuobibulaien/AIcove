part of '../aicove_quickjs.dart';

typedef QuickJsHostCall =
    Future<Object?> Function(
      String method,
      List<dynamic> arguments,
      bool Function() isActive,
    );

/// One asynchronous invocation. The old preset session is deliberately separate.
/// Native JS is interruptible even while its worker cannot service Dart events.
class QuickJsAsyncSession {
  static const maxHeapBytes = 64 * 1024 * 1024;
  static const maxHostCalls = 4;
  static const settleTimeout = Duration(seconds: 5);

  /// One convergence deadline shared by native teardown and in-flight hosts.
  static Future<void> converge(Iterable<Future<void>> operations) async {
    await Future.wait(operations).timeout(settleTimeout);
  }

  bool _active = false;
  bool _used = false;
  bool get isActive => _active;

  Future<String> run(
    String body, {
    required QuickJsHostCall hostCall,
    Duration? timeout,
    int heapBytes = maxHeapBytes,
    bool Function()? isCancelled,
    void Function()? onStop,
    void Function(String)? onText,
  }) async {
    if (_used) throw const QuickJsException('Invocation already closed');
    if (timeout != null && timeout <= Duration.zero) {
      throw const QuickJsException('Deadline must be positive');
    }
    if (heapBytes <= 0 || heapBytes > maxHeapBytes) {
      throw const QuickJsException('Heap exceeds 64 MiB');
    }
    final source = '$_asyncBootstrap\n(async () => {\n$body\n})()';
    if (isCancelled?.call() ?? false) {
      throw const QuickJsException('Invocation cancelled');
    }
    _used = true;
    _active = true;
    final flag = native.cancelNew();
    if (flag == nullptr) {
      throw const QuickJsException('Native allocation failed');
    }
    final events = ReceivePort();
    final result = Completer<String>();
    final closed = Completer<void>();
    final pending = <Future<void>>{};
    final queue = <List>[];
    SendPort? commands;
    Object? stopped;
    var running = 0;
    void stop([Object? reason]) {
      if (!_active) return;
      _active = false;
      stopped = reason;
      queue.clear();
      native.cancelSet(flag);
      onStop?.call();
    }

    late void Function() drain;
    drain = () {
      while (_active && running < maxHostCalls && queue.isNotEmpty) {
        final call = queue.removeAt(0);
        running++;
        final operation = (() async {
          Object? value;
          var ok = true;
          try {
            if (!_active) throw const QuickJsException('Invocation closed');
            value = await hostCall(
              call[1] as String,
              call[2] as List,
              () => _active,
            );
          } catch (error) {
            ok = false;
            value = '$error';
          }
          if (_active) commands?.send(jsonEncode([call[0], ok, value]));
        })();
        pending.add(operation);
        unawaited(
          operation.whenComplete(() {
            pending.remove(operation);
            running--;
            drain();
          }),
        );
      }
    };
    final subscription = events.listen((dynamic event) {
      final data = event as List;
      switch (data[0]) {
        case 'ready':
          commands = data[1] as SendPort;
        case 'text':
          if (_active) {
            for (final value in data[1] as List) {
              onText?.call(value as String);
            }
          }
        case 'calls':
          if (_active) {
            queue.addAll((data[1] as List).cast<List>());
            drain();
          }
        case 'done':
          final error = stopped;
          stop();
          if (!result.isCompleted) {
            if (error != null) {
              result.completeError(error);
            } else if (data[1] == 1) {
              result.complete(data[2] as String);
            } else {
              result.completeError(QuickJsException(data[2] as String));
            }
          }
        case 'closed':
          if (!closed.isCompleted) closed.complete();
      }
    });
    final stopwatch = Stopwatch()..start();
    final worker = await Isolate.spawn(_asyncWorker, [
      events.sendPort,
      flag.address,
      heapBytes,
      timeout?.inMilliseconds ?? 0,
      source,
    ]);
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      if (!_active) return;
      if ((isCancelled?.call() ?? false) ||
          (timeout != null && stopwatch.elapsed >= timeout)) {
        final reason = (isCancelled?.call() ?? false)
            ? const QuickJsException('Invocation cancelled')
            : TimeoutException('JavaScript deadline exceeded', timeout);
        stop(reason);
        if (!result.isCompleted) result.completeError(reason);
      }
    });
    try {
      return await result.future;
    } finally {
      stop();
      timer.cancel();
      // A single convergence budget covers both native shutdown and host I/O.
      // Futures cannot be killed: host commit guards remain false forever.
      var acknowledged = false;
      try {
        await converge([
          closed.future.then<void>((_) {
            acknowledged = true;
          }),
          ...pending,
        ]);
      } on TimeoutException {
        worker.kill(priority: Isolate.immediate);
        throw const QuickJsException(
          'Invocation did not settle within 5 seconds; session forcibly closed',
        );
      } finally {
        await subscription.cancel();
        events.close();
        // Never release a cancellation flag while native code could still
        // reference it. Only an abnormal native shutdown retains this token.
        if (acknowledged) native.cancelFree(flag);
      }
    }
  }
}

String _asyncText(Pointer<Char> pointer) {
  if (pointer == nullptr) return 'Native allocation or conversion failed';
  try {
    return pointer.cast<Utf8>().toDartString();
  } finally {
    native.freeText(pointer);
  }
}

void _asyncWorker(List arguments) {
  final events = arguments[0] as SendPort;
  final runtime = native.asyncCreate(
    Pointer<Void>.fromAddress(arguments[1] as int),
    arguments[2] as int,
    arguments[3] as int,
  );
  if (runtime == nullptr) {
    events.send(['done', -1, 'Cannot create asynchronous runtime']);
    events.send(['closed']);
    return;
  }
  final commands = ReceivePort();
  events.send(['ready', commands.sendPort]);
  var finished = false;
  Timer? timer;
  void finish(int state, [String? error]) {
    if (finished) return;
    finished = true;
    final value =
        error ??
        (state == -2
            ? 'JavaScript interrupted'
            : _asyncText(native.asyncResult(runtime)));
    events.send(['done', state, value]);
    timer?.cancel();
    commands.close();
    native.asyncDestroy(runtime);
    events.send(['closed']);
  }

  void pump() {
    if (finished) return;
    try {
      final state = native.asyncStep(runtime);
      if (state != -2) {
        final pointer = native.asyncTake(runtime);
        if (pointer != nullptr) {
          final packet = jsonDecode(_asyncText(pointer)) as Map;
          if ((packet['text'] as List).isNotEmpty) {
            events.send(['text', packet['text']]);
          }
          if ((packet['calls'] as List).isNotEmpty) {
            events.send(['calls', packet['calls']]);
          }
        }
      }
      if (state != 0) finish(state);
    } catch (error) {
      finish(-1, '$error');
    }
  }

  commands.listen((dynamic data) {
    if (finished) return;
    final text = (data as String).toNativeUtf8();
    try {
      native.asyncDeliver(runtime, text.cast(), utf8.encode(data).length);
    } finally {
      malloc.free(text);
    }
    pump();
  });
  final source = (arguments[4] as String).toNativeUtf8();
  try {
    native.asyncBegin(
      runtime,
      source.cast(),
      utf8.encode(arguments[4] as String).length,
    );
  } finally {
    malloc.free(source);
  }
  timer = Timer.periodic(const Duration(milliseconds: 1), (_) => pump());
  pump();
}

const _asyncBootstrap = r'''
(() => {
  const pending = new Map(), stringify = JSON.stringify.bind(JSON), parse = JSON.parse.bind(JSON);
  let id = 0, calls = [], texts = [];
  const host = (method, args) => new Promise((resolve, reject) => {
    if (typeof method !== 'string' || !Array.isArray(args)) { reject(new Error('Invalid host call')); return; }
    const key = ++id;
    pending.set(key, {resolve, reject}); calls.push([key, method, args]);
  });
  const take = () => { const s = stringify({calls, text: texts}); calls = []; texts = []; return s; };
  const deliver = json => {
    const [key, ok, value] = parse(json), p = pending.get(key);
    if (!p) return;
    pending.delete(key);
    if (ok) p.resolve(value); else p.reject(new Error(value));
  };
  for (const [name, value] of Object.entries({__aq_host: host, __aq_take: take,
      __aq_deliver: deliver, __aq_text: value => { texts.push(String(value)); }})) {
    Object.defineProperty(globalThis, name, {value, writable: false, configurable: false});
  }
})();
''';
