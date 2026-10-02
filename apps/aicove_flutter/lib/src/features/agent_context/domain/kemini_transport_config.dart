/// Reads companion metadata as data; never evaluates imported JavaScript.
class KeminiTransportConfig {
  static const scriptId = '2c7d747c-22d4-4e8b-95f8-5620b552fe6e';

  static Map<String, dynamic> read(Map extensions) {
    Map<String, dynamic> skipped(String diagnostic) => {
      'enabled': false,
      'diagnostics': [diagnostic],
    };
    try {
      final helper = extensions['tavern_helper'];
      if (helper == null) return skipped('transport_unrecognized');
      if (helper is! Map) return skipped('transport_config_read_failed');
      final scripts = helper['scripts'];
      if (scripts == null) return skipped('transport_unrecognized');
      if (scripts is! List) return skipped('transport_config_read_failed');
      final matches = scripts.whereType<Map>().where((item) {
        final content = item['content'];
        return item['id'] == scriptId ||
            (content is String &&
                (content.contains('__keminiAntiTruncation__') ||
                    content.contains('keminiCompanion')));
      }).toList();
      if (matches.isEmpty) return skipped('transport_unrecognized');
      final enabled = matches.where((item) => item['enabled'] == true);
      if (enabled.isEmpty) return skipped('transport_disabled');
      final script = enabled.first;
      final source = script['content'];
      final data = script['data'];
      if (source is! String || (data != null && data is! Map)) {
        return skipped('transport_config_read_failed');
      }
      final stored = data is Map ? data['keminiCompanion'] : null;
      if (stored != null && stored is! Map) {
        return skipped('transport_config_read_failed');
      }
      final setting = stored is Map ? stored['antiTruncationEnabled'] : null;
      if (setting != null && setting is! bool) {
        return skipped('transport_config_read_failed');
      }
      if (setting == false) return skipped('transport_disabled');
      // Read a literal only; missing/new script syntax uses the append fallback.
      final anchor =
          RegExp(
            r'''const\s+transportControlAnchor\s*=\s*["']([^"'\r\n]*)["']\s*;''',
          ).firstMatch(source)?.group(1) ??
          '';
      return {
        'protocol': 'content_tool_v1',
        'enabled': true,
        'anchor': anchor,
        'diagnostics': [if (anchor.isEmpty) 'transport_anchor_missing'],
      };
    } catch (_) {
      return skipped('transport_config_read_failed');
    }
  }
}
