import 'dart:convert';

import '../../../core/sync/cloud_setting_policy.dart';
import '../data/cloud_document.dart';

const lanProtocolVersion = 1;
const lanKinds = {
  'conversations',
  'providers',
  'messages',
  'settings',
  'plugin_presets',
};
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

class LanRevision {
  LanRevision({
    required this.kind,
    required this.id,
    required this.vector,
    required this.payload,
    this.deleted = false,
    List<String> mediaIds = const [],
  }) : mediaIds = mediaIds.toSet().toList()..sort();
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
  String get hash => cloudObjectId(canonicalJson(body));
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
        json['media_ids'] is! List ||
        utf8.encode(canonicalJson(json)).length > lanMaxDocumentBytes) {
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
    final times = revision.payload['setting_times'];
    if (lanSettingKinds.contains(revision.kind)) {
      if (revision.payload['setting_times_version'] != 1 ||
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
    if (revision.kind == 'settings' &&
        revision.payload['key'] == cloudUiModelsKey) {
      final value = revision.payload['json_value'];
      if (value is! String ||
          jsonDecode(value) is! Map ||
          (jsonDecode(value) as Map).keys.any(localGeneralSettings.contains) ||
          (times as Map).keys.any(localGeneralSettings.contains)) {
        throw const LanSyncFailure('通用设置只允许保存在本机');
      }
    }
    return revision;
  }
}

Map<String, dynamic> _content(Map<String, dynamic> payload) => Map.of(payload)
  ..remove('setting_times_version')
  ..remove('setting_times');

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
      payload: payload,
      deleted: joined.deleted,
      mediaIds: lanMediaReferences(payload).intersection(allowed).toList(),
    );
  }
  return [joined];
}
