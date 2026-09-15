/// Bounded, content-free statistics over already decoded history payloads.
/// Counts UTF-16 string values, not JSON syntax, keys, file bytes or heap size.
class HistoryPayloadStats {
  HistoryPayloadStats({this.maxNodes = 12000, this.maxDepth = 16});

  final int maxNodes;
  final int maxDepth;
  int _nodes = 0;
  bool _truncated = false;
  final Map<String, int> _chars = {};

  static const fields = <String, String>{
    'rawReplyText': 'payloadReplyChars',
    'processedText': 'payloadProcessedChars',
    'hiddenThoughtParts': 'payloadThoughtChars',
    'pluginEvents': 'payloadPluginEventChars',
    'pluginContents': 'payloadPluginContentChars',
    'toolAudioResults': 'payloadAudioResultChars',
    'toolCalls': 'payloadToolArgsChars',
    'rawToolResults': 'payloadToolResultChars',
    'projectedMessages': 'payloadProjectionChars',
    'supplementInsertOps': 'payloadSupplementChars',
  };

  void add(Map<String, dynamic>? payload) {
    if (payload == null) return;
    for (final entry in payload.entries) {
      if (_nodes >= maxNodes) {
        _truncated = true;
        break;
      }
      final field = fields[entry.key] ?? 'payloadOtherChars';
      _chars[field] = (_chars[field] ?? 0) + _count(entry.value, 0);
    }
  }

  int _count(Object? value, int depth) {
    if (_nodes >= maxNodes || depth > maxDepth) {
      _truncated = true;
      return 0;
    }
    _nodes++;
    if (value is String) return value.length;
    final Iterable<Object?> values;
    if (value is Map) {
      values = value.values;
    } else if (value is List) {
      values = value;
    } else {
      return 0;
    }
    var chars = 0;
    for (final item in values) {
      if (_nodes >= maxNodes) {
        _truncated = true;
        break;
      }
      chars += _count(item, depth + 1);
    }
    return chars;
  }

  Map<String, Object?> get values => {
        for (final field in fields.values) field: _chars[field] ?? 0,
        'payloadOtherChars': _chars['payloadOtherChars'] ?? 0,
        'payloadScanNodes': _nodes,
        'payloadScanTruncated': _truncated,
      };
}
