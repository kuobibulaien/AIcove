bool _sameJson(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  return a == b;
}

/// JSON Schema subset used at the common tool execution boundary. Unknown
/// keywords are left to the handler; invalid inputs never reach side effects.
List<Map<String, String>> validateToolArguments(
  Object? value,
  Map<String, dynamic> schema,
) {
  final errors = <Map<String, String>>[];
  void visit(Object? value, Map rule, String path) {
    void fail(String message) => errors.add({'path': path, 'message': message});
    bool matches(String type) => switch (type) {
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'integer' =>
        value is num && value.isFinite && value == value.roundToDouble(),
      'number' => value is num && value.isFinite,
      'boolean' => value is bool,
      'null' => value == null,
      _ => true,
    };
    final type = rule['type'];
    if (type is String && !matches(type) ||
        type is List && !type.whereType<String>().any(matches)) {
      fail('Expected $type');
      return;
    }
    final choices = rule['enum'];
    if (choices is List && !choices.any((v) => _sameJson(v, value))) {
      fail('Value is not in enum');
    }
    if (rule.containsKey('const') && !_sameJson(rule['const'], value)) {
      fail('Value does not match const');
    }
    if (value is Map) {
      for (final key in rule['required'] as List? ?? const []) {
        if (!value.containsKey(key))
          errors.add({
            'path': '$path.$key',
            'message': 'Required property missing',
          });
      }
      final properties = rule['properties'] as Map? ?? const {};
      for (final entry in value.entries) {
        final child = properties[entry.key];
        if (child is Map) {
          visit(entry.value, child, '$path.${entry.key}');
        } else if (rule['additionalProperties'] == false) {
          errors.add({
            'path': '$path.${entry.key}',
            'message': 'Unknown property',
          });
        } else if (rule['additionalProperties'] is Map) {
          visit(
            entry.value,
            rule['additionalProperties'] as Map,
            '$path.${entry.key}',
          );
        }
      }
    }
    if (value is List) {
      if (rule['minItems'] is num && value.length < (rule['minItems'] as num))
        fail('Too few items');
      if (rule['maxItems'] is num && value.length > (rule['maxItems'] as num))
        fail('Too many items');
      if (rule['items'] is Map) {
        for (var i = 0; i < value.length; i++) {
          visit(value[i], rule['items'] as Map, '$path[$i]');
        }
      }
    }
    if (value is String) {
      if (rule['minLength'] is num &&
          value.runes.length < (rule['minLength'] as num))
        fail('String too short');
      if (rule['maxLength'] is num &&
          value.runes.length > (rule['maxLength'] as num))
        fail('String too long');
    }
    if (value is num) {
      if (rule['minimum'] is num && value < (rule['minimum'] as num))
        fail('Below minimum');
      if (rule['maximum'] is num && value > (rule['maximum'] as num))
        fail('Above maximum');
    }
  }

  visit(value, schema, r'$');
  return errors;
}
