import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Retain the raw TCP handle through the TLS handshake. Dart's convenience
/// SecureSocket.startConnect cancellation only owns the TCP-connect phase;
/// after TCP succeeds, a peer that never finishes TLS otherwise stays open.
Future<ConnectionTask<Socket>> connectCancellableTls(
  InternetAddress address,
  int port, {
  SecurityContext? context,
}) async {
  final tcp = await RawSocket.startConnect(address, port);
  RawSocket? raw;
  _TlsSocket? established;
  var cancelled = false;
  final socket = (() async {
    raw = await tcp.socket;
    if (cancelled) {
      raw!.close();
      throw const SocketException('Connection cancelled');
    }
    try {
      final secure = await RawSecureSocket.secure(
        raw!,
        host: address.host,
        context: context,
      );
      if (cancelled) {
        secure.close();
        throw const SocketException('Connection cancelled');
      }
      return established = _TlsSocket(secure);
    } catch (_) {
      raw!.close();
      rethrow;
    }
  })();
  return ConnectionTask.fromSocket(socket, () {
    cancelled = true;
    tcp.cancel();
    raw?.close();
    established?.destroy();
  });
}

/// Adapts the SDK's TLS streams to Socket for HttpClient.
/// IOSink serializes writes and the raw write event supplies backpressure.
class _TlsSocket extends Stream<Uint8List> implements Socket {
  _TlsSocket(this._raw) {
    _incoming = StreamController<Uint8List>(
      sync: true,
      onListen: () => _raw.readEventsEnabled = true,
      onPause: () => _raw.readEventsEnabled = false,
      onResume: () => _raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _sink = IOSink(_TlsConsumer(this), encoding: utf8);
    _raw.readEventsEnabled = false;
    _raw.writeEventsEnabled = false;
    _subscription = _raw.listen(
      _event,
      onError: (Object error, StackTrace stack) {
        if (!_incoming.isClosed) _incoming.addError(error, stack);
        _ready?.completeError(error, stack);
        _ready = null;
        destroy();
      },
      onDone: () {
        if (!_incoming.isClosed) _incoming.close();
      },
    );
  }
  final RawSecureSocket _raw;
  late final StreamController<Uint8List> _incoming;
  late final IOSink _sink;
  late final StreamSubscription<RawSocketEvent> _subscription;
  Completer<void>? _ready;
  bool _destroyed = false;
  void _event(RawSocketEvent event) {
    if (_destroyed) return;
    if (event == RawSocketEvent.read) {
      while (!_incoming.isPaused) {
        final bytes = _raw.read();
        if (bytes == null) break;
        _incoming.add(bytes);
      }
    } else if (event == RawSocketEvent.write) {
      _raw.writeEventsEnabled = false;
      _ready?.complete();
      _ready = null;
    } else if (event == RawSocketEvent.readClosed ||
        event == RawSocketEvent.closed) {
      if (!_incoming.isClosed) _incoming.close();
    }
  }

  Future<void> _write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_destroyed) throw const SocketException('Socket closed');
      final written = _raw.write(bytes, offset, bytes.length - offset);
      if (written > 0) {
        offset += written;
        continue;
      }
      _ready = Completer<void>();
      _raw.writeEventsEnabled = true;
      await _ready!.future;
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _ready?.completeError(const SocketException('Socket closed'));
    _ready = null;
    _subscription.cancel();
    _raw.close();
    if (!_incoming.isClosed) _incoming.close();
    _sink.close().ignore();
  }

  @override
  InternetAddress get address => _raw.address;
  @override
  int get port => _raw.port;
  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;
  @override
  int get remotePort => _raw.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future<void> flush() => _sink.flush();
  @override
  Future<void> close() => _sink.close();
  @override
  Future<void> get done => _sink.done;
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
}

class _TlsConsumer implements StreamConsumer<List<int>> {
  _TlsConsumer(this.socket);
  final _TlsSocket socket;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      await socket._write(bytes);
    }
  }

  @override
  Future<void> close() async {
    if (!socket._destroyed) socket._raw.shutdown(SocketDirection.send);
  }
}
