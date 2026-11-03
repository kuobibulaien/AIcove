import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'lan_transport.dart';

abstract interface class LanDiscovery {
  bool get isRunning;
  Future<void> start(
    String deviceId,
    int port,
    void Function(String, List<LanEndpoint>) found,
  );
  Future<void> stop();
}

abstract interface class LanDiscoveryLifecycle {
  set onStopped(void Function()? callback);
}

class BonjourLanDiscovery implements LanDiscovery, LanDiscoveryLifecycle {
  // The native registration deadline is 5 seconds. Also bound the Dart wait
  // so a lost platform reply still releases the partially registered action.
  static const _startTimeout = Duration(seconds: 6);
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  StreamSubscription<BonsoirBroadcastEvent>? _broadcastEvents;
  bool _running = false;
  @override
  void Function()? onStopped;
  @override
  bool get isRunning => _running;
  int _generation = 0;
  Future<void> _lifecycle = Future.value();

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> start(
    String deviceId,
    int port,
    void Function(String, List<LanEndpoint>) found,
  ) => _serialize(() => _start(deviceId, port, found));

  Future<void> _start(
    String deviceId,
    int port,
    void Function(String, List<LanEndpoint>) found,
  ) async {
    await _stop();
    final generation = _generation;
    final broadcast = BonsoirBroadcast(
      printLogs: false,
      service: BonsoirService(
        name: 'AIcove-${deviceId.substring(0, deviceId.length.clamp(0, 8))}',
        type: '_aicove-sync._tcp',
        port: port,
        attributes: {'device': deviceId, 'v': '1'},
      ),
    );
    final discovery = BonsoirDiscovery(
      type: '_aicove-sync._tcp',
      printLogs: false,
    );
    _broadcast = broadcast;
    _discovery = discovery;
    var started = false;
    var notified = false;
    void stopped() {
      if (generation != _generation) return;
      _running = false;
      // Startup failures belong to start()'s caller, not its recovery loop.
      if (!started || notified) return;
      notified = true;
      onStopped?.call();
    }

    try {
      await broadcast.initialize();
      if (generation != _generation) return;
      _running = true;
      _broadcastEvents = broadcast.eventStream!.listen(
        (event) {
          if (event is BonsoirBroadcastStoppedEvent) stopped();
        },
        onError: (Object _) => stopped(),
        onDone: stopped,
      );
      await broadcast.start().timeout(_startTimeout);
      await discovery.initialize();
      if (generation != _generation) return;
      _events = discovery.eventStream!.listen(
        (event) {
          if (generation != _generation) return;
          if (event is BonsoirDiscoveryStoppedEvent) stopped();
          if (event is BonsoirDiscoveryServiceFoundEvent) {
            event.service.resolve(discovery.serviceResolver);
          }
          if (event is BonsoirDiscoveryServiceResolvedEvent ||
              event is BonsoirDiscoveryServiceUpdatedEvent) {
            final service = event.service;
            final id = service?.attributes['device'];
            if (id == null ||
                id == deviceId ||
                service!.attributes['v'] != '1' ||
                service.port <= 0 ||
                service.port > 65535) {
              return;
            }
            final endpoints = service.hostAddresses
                .where(lanAddress)
                .map((host) => LanEndpoint(host, service.port))
                .toList();
            if (endpoints.isNotEmpty) found(id, endpoints);
          }
        },
        onError: (Object _) => stopped(),
        onDone: stopped,
      );
      await discovery.start();
      if (!_running) throw StateError('Bonjour stopped during startup');
      started = true;
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() => _serialize(_stop);

  Future<void> _stop() async {
    ++_generation;
    _running = false;
    await _events?.cancel();
    _events = null;
    await _broadcastEvents?.cancel();
    _broadcastEvents = null;
    final b = _broadcast, d = _discovery;
    _broadcast = null;
    _discovery = null;
    try {
      if (d?.isReady == true) await d!.stop();
    } catch (_) {
      /* Platform already stopped. */
    }
    try {
      if (b?.isReady == true) await b!.stop();
    } catch (_) {
      /* Platform already stopped. */
    }
  }
}
