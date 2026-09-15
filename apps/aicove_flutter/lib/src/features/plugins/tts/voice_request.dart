import 'dart:async';
import '../domain/plugin.dart';
import 'tts_config.dart';
import 'tts_service.dart';

/// Request-local, memory-only execution context. Never serialize credentials
/// into PluginEvent.data, message payloads, or preset exports.
class VoiceRequest {
  VoiceRequest({required this.ownerId, this.service, this.error});
  final String ownerId;
  final TtsService? service;
  final String? error;
  TtsConfig? get config => service?.config;

  static final Object _zoneKey = Object();
  static final Expando<VoiceRequest> _events = Expando<VoiceRequest>();
  static VoiceRequest? get current => Zone.current[_zoneKey] as VoiceRequest?;
  T run<T>(T Function() body) => runZoned(body, zoneValues: {_zoneKey: this});
  void attach(PluginEvent event) => _events[event] = this;
  static VoiceRequest? forEvent(PluginEvent event) => _events[event];
  static VoiceRequest? forEvents(List<PluginEvent> events) {
    for (final event in events) {
      final request = _events[event];
      if (request != null) return request;
    }
    return null;
  }
}
