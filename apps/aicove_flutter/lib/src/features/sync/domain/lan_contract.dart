import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/sync/cloud_setting_policy.dart';
import '../data/cloud_document.dart';

const lanProtocolVersion = 1;
const lanKinds = {
  'conversations',
  'providers',
  'messages',
  'settings',
  'plugin_presets',
  ...lanContextMemoryKinds,
};
const lanContextMemoryKinds = {
  'context_summaries',
  'memory_items',
  'memory_progress',
};

int compareLanManifestCursors(
  String a,
  String b, {
  bool includeContextMemory = false,
}) {
  if (a.isEmpty || b.isEmpty) return a.compareTo(b);
  if (includeContextMemory) {
    final ap = a.startsWith('conversations/') ? 0 : 1;
    final bp = b.startsWith('conversations/') ? 0 : 1;
    if (ap != bp) return ap.compareTo(bp);
  }
  return a.compareTo(b);
}

const lanSettingKinds = {'conversations', 'providers', 'settings'};
const lanMaxDocumentBytes = 4 * 1024 * 1024;

class LanSyncFailure implements Exception {
  const LanSyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A vector describes observed edits, independently of a server or wall clock.
Map<String, int> joinLanVectors(Iterable<Map<String, int>> vectors) {
  final result = <String, int>{};
  for (final vector in vectors) {
    for (final entry in vector.entries) {
      if (entry.value > (result[entry.key] ?? 0)) {
        result[entry.key] = entry.value;
      }
    }
  }
  return result;
}

bool lanDominates(Map<String, int> a, Map<String, int> b) =>
    b.entries.every((entry) => (a[entry.key] ?? 0) >= entry.value) &&
    a.entries.any((entry) => entry.value > (b[entry.key] ?? 0));

Object? _freezeLanJson(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freezeLanJson(entry.value),
    });
  }
  if (value is List) return List.unmodifiable(value.map(_freezeLanJson));
  return value;
}

class LanRevision {
  LanRevision({
    required this.kind,
    required this.id,
    required Map<String, int> vector,
    required Map<String, dynamic> payload,
    this.deleted = false,
    List<String> mediaIds = const [],
  }) : vector = Map.unmodifiable(vector),
       payload = _freezeLanJson(payload) as Map<String, dynamic>,
       mediaIds = List.unmodifiable(mediaIds.toSet().toList()..sort());
  final String kind, id;
  final Map<String, int> vector;
  final Map<String, dynamic> payload;
  final bool deleted;
  final List<String> mediaIds;
  String get key => '$kind/$id';
  Map<String, dynamic> get body => {
    'protocol': lanProtocolVersion,
    'kind': kind,
    'entity_id': id,
    'vector': vector,
    'payload': payload,
    'deleted': deleted,
    'media_ids': mediaIds,
  };
  late final List<int> _bodyBytes = utf8.encode(canonicalJson(body));
  late final String hash = sha256.convert(_bodyBytes).toString();
  Map<String, dynamic> toJson() => {...body, 'hash': hash};

  factory LanRevision.fromJson(Map<String, dynamic> json) {
    if (json['protocol'] != lanProtocolVersion ||
        !lanKinds.contains(json['kind']) ||
        json['entity_id'] is! String ||
        (json['entity_id'] as String).isEmpty ||
        (json['entity_id'] as String).length > 200 ||
        json['vector'] is! Map ||
        json['payload'] is! Map ||
        json['deleted'] is! bool ||
        json['media_ids'] is! List) {
      throw const LanSyncFailure('局域网数据格式无效或版本不兼容');
    }
    final vector = <String, int>{};
    final stamps = json['vector'] as Map;
    if (stamps.isEmpty || stamps.length > 64) {
      throw const LanSyncFailure('设备修改记录无效');
    }
    for (final entry in stamps.entries) {
      if (entry.key is! String ||
          (entry.key as String).length > 100 ||
          (entry.key as String).isEmpty ||
          entry.value is! int ||
          (entry.value as int) < 1 ||
          (entry.value as int) > 9007199254740991) {
        throw const LanSyncFailure('设备修改记录无效');
      }
      vector[entry.key as String] = entry.value as int;
    }
    final media = json['media_ids'] as List;
    if (media.length > 500 ||
        media.any(
          (v) => v is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(v),
        )) {
      throw const LanSyncFailure('附件身份无效');
    }
    final revision = LanRevision(
      kind: json['kind'] as String,
      id: json['entity_id'] as String,
      vector: vector,
      payload: Map<String, dynamic>.from(json['payload'] as Map),
      deleted: json['deleted'] as bool,
      mediaIds: media.cast<String>(),
    );
    if (json['hash'] != revision.hash) throw const LanSyncFailure('同步内容校验失败');
    // Extra fields and duplicate media IDs remain part of the wire size.
    final int? knownBytes =
        json.length == 8 && media.length == revision.mediaIds.length
        ? null
        : utf8.encode(canonicalJson(json)).length;
    revision.validate(knownDocumentBytes: knownBytes);
    return revision;
  }

  void validate({int? knownDocumentBytes}) {
    if (!lanKinds.contains(kind) ||
        id.isEmpty ||
        id.length > 200 ||
        (knownDocumentBytes ?? _bodyBytes.length + 74) > lanMaxDocumentBytes) {
      throw const LanSyncFailure('局域网数据格式无效或版本不兼容');
    }
    if (vector.isEmpty ||
        vector.length > 64 ||
        vector.entries.any(
          (entry) =>
              entry.key.isEmpty ||
              entry.key.length > 100 ||
              entry.value < 1 ||
              entry.value > 9007199254740991,
        )) {
      throw const LanSyncFailure('设备修改记录无效');
    }
    if (mediaIds.length > 500 ||
        mediaIds.any((id) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(id))) {
      throw const LanSyncFailure('附件身份无效');
    }
    final times = payload['setting_times'];
    if (lanSettingKinds.contains(kind)) {
      if (payload['setting_times_version'] != 1 ||
          times is! Map ||
          times.length > 1000) {
        throw const LanSyncFailure('设置缺少修改时间记录');
      }
      for (final entry in times.entries) {
        final stamp = entry.value;
        if (entry.key is! String ||
            (entry.key as String).length > 200 ||
            stamp is! Map ||
            stamp['at_ms'] is! int ||
            stamp['at_ms'] < 0 ||
            stamp['at_ms'] > 253402300799999 ||
            stamp['device_id'] is! String ||
            (stamp['device_id'] as String).length > 100) {
          throw const LanSyncFailure('设置修改时间无效');
        }
      }
    }
    // Device-local general fields are ignored on apply (keepLocalGeneralSettings),
    // not rejected: the local list grows over time, and revisions written
    // before a field became local must stay readable.
    if (kind == 'settings' && payload['key'] == cloudUiModelsKey) {
      final value = payload['json_value'];
      if (value is! String || jsonDecode(value) is! Map) {
        throw const LanSyncFailure('通用设置格式无效');
      }
    }
  }
}

Map<String, dynamic> _content(Map<String, dynamic> payload) => Map.of(payload)
  ..remove('setting_times_version')
  ..remove('setting_times')
  ..remove('client_schema');

Set<String> lanMediaReferences(Object? value) {
  final result = <String>{};
  void visit(Object? item) {
    if (item is Map) {
      item.values.forEach(visit);
    } else if (item is List) {
      item.forEach(visit);
    } else if (item is String) {
      if (RegExp(r'^aicove-media://[a-f0-9]{64}$').hasMatch(item)) {
        result.add(item.substring('aicove-media://'.length));
      } else if (item.startsWith('{') || item.startsWith('[')) {
        try {
          visit(jsonDecode(item));
        } on FormatException {
          /* Plain text. */
        }
      }
    }
  }

  visit(value);
  return result;
}

/// Returns null for ambiguous legacy edits or incompatible document shapes.
Map<String, dynamic>? _mergeSettings(
  String kind,
  Map<String, dynamic> a,
  Map<String, dynamic> b,
) {
  final row = kind != 'settings';
  if (row && (a['row'] is! Map || b['row'] is! Map)) return null;
  // Business deletion is normally a soft-delete field, not a missing row.
  // Concurrent deletion and editing require an explicit choice.
  if (row &&
      (a['row']['deleted_at'] != null) != (b['row']['deleted_at'] != null)) {
    return null;
  }
  if (!row && (a['storage'] != 'preference' || b['storage'] != 'preference')) {
    return null;
  }
  Map<String, dynamic> identity(Map<String, dynamic> payload) {
    final result = _content(payload)..remove(row ? 'row' : 'json_value');
    if (row) {
      result['identity'] = {
        for (final field in ['id', 'created_at'])
          if ((payload['row'] as Map).containsKey(field))
            field: payload['row'][field],
      };
    }
    return result;
  }

  if (canonicalJson(identity(a)) != canonicalJson(identity(b))) return null;
  final key = a['key'] as String? ?? '';
  Map<String, dynamic> fields(Map<String, dynamic> p) => row
      ? {
          for (final entry in (p['row'] as Map).entries)
            if (!{'id', 'created_at', 'updated_at'}.contains(entry.key))
              entry.key as String: entry.value,
        }
      : cloudPreferenceFields(key, p['json_value']);
  final left = fields(a), right = fields(b);
  final lt = a['setting_times'] as Map, rt = b['setting_times'] as Map;
  final values = <String, dynamic>{}, times = <String, dynamic>{};
  for (final field in {
    ...left.keys,
    ...right.keys,
    ...lt.keys.cast<String>(),
    ...rt.keys.cast<String>(),
  }) {
    final l = lt[field] as Map? ?? {}, r = rt[field] as Map? ?? {};
    final la = l['at_ms'] as int? ?? 0, ra = r['at_ms'] as int? ?? 0;
    final ld = l['device_id'] as String? ?? '',
        rd = r['device_id'] as String? ?? '';
    final same =
        left.containsKey(field) == right.containsKey(field) &&
        canonicalJson(left[field]) == canonicalJson(right[field]);
    if (!same && ((la == 0 && ra == 0) || (la == ra && ld == rd))) return null;
    final takeRight = ra > la || (ra == la && rd.compareTo(ld) > 0);
    final source = takeRight ? right : left;
    if (source.containsKey(field)) values[field] = source[field];
    final stamp = takeRight ? rt[field] : lt[field];
    if (stamp != null) times[field] = stamp;
  }
  final payload = {...a, 'setting_times': times};
  if (row) {
    payload['row'] = {
      ...a['row'] as Map,
      ...values,
      if (a['row']['updated_at'] is int && b['row']['updated_at'] is int)
        'updated_at': a['row']['updated_at'] > b['row']['updated_at']
            ? a['row']['updated_at']
            : b['row']['updated_at'],
    };
    for (final field in left.keys.where((key) => !values.containsKey(key))) {
      (payload['row'] as Map).remove(field);
    }
  } else {
    final av = a['json_value'], bv = b['json_value'];
    bool object(Object? value) {
      try {
        return value is String && jsonDecode(value) is Map;
      } on FormatException {
        return false;
      }
    }

    if (object(av) != object(bv)) return null;
    payload['json_value'] = object(av)
        ? canonicalJson(values)
        : values['value'];
  }
  return payload;
}

/// Deterministic joins can be independently calculated by every peer.
List<LanRevision> reduceLanHeads(Iterable<LanRevision> input) {
  var heads = {for (final r in input) r.hash: r}.values.toList();
  if (heads.length > 1 &&
      heads.every(
        (r) =>
            r.kind == 'memory_progress' &&
            !r.deleted &&
            r.key == heads.first.key &&
            r.payload['row'] is Map,
      )) {
    int compare(LanRevision a, LanRevision b) {
      final ar = a.payload['row'] as Map, br = b.payload['row'] as Map;
      final generation = ((ar['generation'] as num?) ?? 0).compareTo(
        (br['generation'] as num?) ?? 0,
      );
      if (generation != 0) return generation;
      final until = ((ar['until_at'] as num?) ?? -1).compareTo(
        (br['until_at'] as num?) ?? -1,
      );
      if (until != 0) return until;
      final updated = ((ar['updated_at'] as num?) ?? 0).compareTo(
        (br['updated_at'] as num?) ?? 0,
      );
      return updated != 0 ? updated : a.hash.compareTo(b.hash);
    }

    heads.sort(compare);
    final chosen = heads.last;
    return [
      LanRevision(
        kind: chosen.kind,
        id: chosen.id,
        vector: joinLanVectors(heads.map((r) => r.vector)),
        payload: chosen.payload,
        mediaIds: chosen.mediaIds,
      ),
    ];
  }
  heads =
      heads
          .where(
            (r) => !heads.any((other) => lanDominates(other.vector, r.vector)),
          )
          .toList()
        ..sort((a, b) => a.hash.compareTo(b.hash));
  if (heads.length < 2 || heads.any((r) => r.key != heads.first.key)) {
    return heads;
  }
  var joined = heads.first;
  for (final other in heads.skip(1)) {
    if (joined.deleted != other.deleted) return heads;
    Map<String, dynamic>? payload;
    if (!joined.deleted && lanSettingKinds.contains(joined.kind)) {
      payload = _mergeSettings(joined.kind, joined.payload, other.payload);
    } else if (canonicalJson(_content(joined.payload)) ==
            canonicalJson(_content(other.payload)) &&
        canonicalJson(joined.mediaIds) == canonicalJson(other.mediaIds)) {
      payload = joined.payload;
    }
    if (payload == null) return heads;
    final allowed = {...joined.mediaIds, ...other.mediaIds};
    joined = LanRevision(
      kind: joined.kind,
      id: joined.id,
      vector: joinLanVectors([joined.vector, other.vector]),
      payload: {
        ...payload,
        if (joined.payload['client_schema'] is int ||
            other.payload['client_schema'] is int)
          'client_schema': [
            joined.payload['client_schema'],
            other.payload['client_schema'],
          ].whereType<int>().reduce((a, b) => a > b ? a : b),
      },
      deleted: joined.deleted,
      mediaIds: lanMediaReferences(payload).intersection(allowed).toList(),
    );
  }
  return [joined];
}
