import 'dart:convert';

import 'package:crypto/crypto.dart';

class CloudLocalDocument {
  const CloudLocalDocument(this.kind, this.id, this.payload);
  final String kind;
  final String id;
  final Map<String, dynamic> payload;

  /// Device-local intermediate state, never an outgoing put or a deletion.
  bool get isSendingMessage =>
      kind == 'messages' && (payload['row'] as Map?)?['status'] == 'sending';
  // This value is a comparison token, not a second copy of raw history.
  String get localJson => 'sha256:${cloudObjectId(canonicalJson(payload))}';
}

class CloudWireDocument {
  const CloudWireDocument(this.payload, this.mediaIds);
  final Map<String, dynamic> payload;
  final List<String> mediaIds;
}

String canonicalJson(Object? value) {
  Object? normalize(Object? node) {
    if (node is Map) {
      final keys = node.keys.map((e) => e.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(node[key])};
    }
    if (node is List) return node.map(normalize).toList();
    return node;
  }

  return jsonEncode(normalize(value));
}

String cloudObjectId(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class CloudSyncFailure implements Exception {
  const CloudSyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
