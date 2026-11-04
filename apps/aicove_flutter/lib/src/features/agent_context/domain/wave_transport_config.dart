/// Recognizes companion scripts as metadata, without executing imported code.
class WaveTransportConfig {
  static const contextId = '53b20f91-395f-45a9-8d39-779e4d164ffd';
  static const deliveryIds = {
    'd43a6f18-90c5-4b7e-a1f2-5d7c3e9a8b64',
    'b7c2d9a4-2f61-4e8b-9a3d-6f1c8e0b5a72',
  };

  static Map<String, dynamic>? read(Map extensions) {
    final helper = extensions['tavern_helper'];
    final scripts = helper is Map ? helper['scripts'] : null;
    if (scripts is! List) return null;
    bool context(Map item) {
      final source = item['content'];
      return item['id'] == contextId ||
          (source is String &&
              source.contains('[[WAVE_CONTEXT_BEGIN_07_8d2c91]]') &&
              source.contains('wave_context_reference'));
    }

    bool delivery(Map item) {
      final source = item['content'];
      return deliveryIds.contains(item['id']) ||
          (source is String &&
              source.contains('wave_context_reference') &&
              (source.contains('__WAVE_DELIVERY_CHANNEL_V2__') ||
                  source.contains('manuscript')));
    }

    final entries = scripts.whereType<Map>().toList();
    final contexts = entries.where(context).toList();
    if (contexts.isEmpty) return null;
    final enabled = contexts.any((item) => item['enabled'] == true);
    return {
      'protocol': 'wave_context_v1',
      'enabled': enabled,
      'delivery': entries.any(
        (item) => !context(item) && delivery(item) && item['enabled'] == true,
      ),
      'diagnostics': <String>[if (!enabled) 'transport_disabled'],
    };
  }
}
