import 'dart:async';
import 'package:bonsoir/bonsoir.dart';
import 'lan_transport.dart';

abstract interface class LanDiscovery {
  Future<void> start(
    String deviceId,
    int port,
    void Function(String, List<LanEndpoint>) found,
  );
  Future<void> stop();
}

class BonjourLanDiscovery implements LanDiscovery {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _events;
  int _generation = 0;
  @override
  Future<void> start(
    String deviceId,
    int port,
    void Function(String, List<LanEndpoint>) found,
  ) async {
    await stop();
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
    try {
      await broadcast.initialize();
      if (generation != _generation) return;
      await broadcast.start();
      await discovery.initialize();
      if (generation != _generation) return;
      _events = discovery.eventStream!.listen((event) {
        if (generation != _generation) return;
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
      });
      await discovery.start();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    ++_generation;
    await _events?.cancel();
    _events = null;
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
