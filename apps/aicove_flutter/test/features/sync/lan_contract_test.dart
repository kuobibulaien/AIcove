import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_document.dart';
import 'package:aicove_flutter/src/features/sync/domain/lan_contract.dart';

LanRevision setting(
  String device,
  int clock,
  Object? value, {
  Map<String, int>? vector,
}) => LanRevision(
  kind: 'conversations',
  id: 'role',
  vector: vector ?? {device: 1},
  payload: {
    'client_schema': 18,
    'row': {'id': 'role', 'created_at': 1, 'voice_file': value},
    'setting_times_version': 1,
    'setting_times': {
      'voice_file': {'at_ms': clock, 'device_id': device},
    },
  },
);

void main() {
  for (final readHashFirst in [false, true]) {
    test('constructor snapshots inputs (hash read first: $readHashFirst)', () {
      final vector = {'phone': 1};
      final media = ['b' * 64, 'a' * 64, 'b' * 64];
      final nested = <String, dynamic>{'text': '中文', 'null': null};
      final items = <dynamic>[nested, [true, 1, 1.5]];
      final payload = <String, dynamic>{'items': items};
      final originalPayload = canonicalJson(payload);
      final revision = LanRevision(
        kind: 'messages',
        id: 'm',
        vector: vector,
        payload: payload,
        mediaIds: media,
      );
      expect(canonicalJson(revision.payload), originalPayload);
      final originalBody = canonicalJson(revision.body);
      final expectedHash = cloudObjectId(originalBody);
      if (readHashFirst) expect(revision.hash, expectedHash);

      vector['phone'] = 2;
      media.clear();
      nested['text'] = 'changed';
      (items[1] as List).clear();
      items.add('extra');
      payload['extra'] = true;

      expect(canonicalJson(revision.body), originalBody);
      expect(revision.vector, {'phone': 1});
      expect(revision.mediaIds, ['a' * 64, 'b' * 64]);
      expect(revision.hash, expectedHash);
    });
    test('fromJson snapshots inputs (hash read first: $readHashFirst)', () {
      final source = LanRevision(
        kind: 'messages',
        id: 'm',
        vector: {'phone': 1},
        payload: {
          'items': [
            {'text': '中文'},
          ],
        },
        mediaIds: ['a' * 64],
      );
      final wire =
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;
      final revision = LanRevision.fromJson(wire);
      final originalBody = canonicalJson(revision.body);
      if (readHashFirst) expect(revision.hash, source.hash);

      (wire['vector'] as Map)['phone'] = 2;
      (wire['media_ids'] as List).clear();
      wire['payload']['items'][0]['text'] = 'changed';
      (wire['payload']['items'] as List).clear();
      (wire['payload'] as Map)['extra'] = true;
      wire['entity_id'] = 'changed';

      expect(canonicalJson(revision.body), originalBody);
      expect(revision.hash, source.hash);
    });
  }
  test('revision collections are recursively unmodifiable', () {
    final revision = LanRevision(
      kind: 'messages',
      id: 'm',
      vector: {'phone': 1},
      payload: {
        'row': {
          'items': [
            {'text': 'original'},
            [1],
          ],
        },
      },
      mediaIds: ['a' * 64],
    );
    expect(() => revision.vector['phone'] = 2, throwsUnsupportedError);
    expect(() => revision.mediaIds.clear(), throwsUnsupportedError);
    expect(() => revision.payload.clear(), throwsUnsupportedError);
    expect(() => revision.payload['row'].clear(), throwsUnsupportedError);
    final items = revision.payload['row']['items'] as List;
    expect(() => items.clear(), throwsUnsupportedError);
    expect(() => items[0]['text'] = 'changed', throwsUnsupportedError);
    expect(() => (items[1] as List).clear(), throwsUnsupportedError);
  });
  test('body and toJson cannot expose mutable revision state', () {
    final revision = setting('phone', 100, 'original');
    final originalBody = canonicalJson(revision.body);
    final expectedHash = cloudObjectId(originalBody);
    for (final exposed in [revision.body, revision.toJson()]) {
      exposed['entity_id'] = 'changed';
      expect(() => exposed['vector']['phone'] = 2, throwsUnsupportedError);
      expect(() => exposed['media_ids'].clear(), throwsUnsupportedError);
      expect(() => exposed['payload'].clear(), throwsUnsupportedError);
      expect(
        () => exposed['payload']['row']['voice_file'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => exposed['payload']['setting_times']['voice_file']['at_ms'] = 0,
        throwsUnsupportedError,
      );
      exposed.clear();
    }
    expect(canonicalJson(revision.body), originalBody);
    expect(revision.hash, expectedHash);
    expect(revision.toJson()['hash'], expectedHash);
  });
  test('hash reuses its first computed string', () {
    final revision = setting('phone', 100, 'original');
    final hash = revision.hash;
    expect(hash, cloudObjectId(canonicalJson(revision.body)));
    expect(identical(revision.hash, hash), isTrue);
    expect(identical(revision.toJson()['hash'], hash), isTrue);
  });
  test('wire size includes unknown fields and counts UTF-8 bytes', () {
    final source = setting('phone', 100, '中文');
    final wire = {...source.toJson(), 'unknown': ''};
    final available =
        lanMaxDocumentBytes - utf8.encode(canonicalJson(wire)).length;
    wire['unknown'] = '中' * (available ~/ 3) + 'a' * (available % 3);
    expect(utf8.encode(canonicalJson(wire)), hasLength(lanMaxDocumentBytes));
    expect(LanRevision.fromJson(wire).hash, source.hash);
    for (final suffix in ['a', '中']) {
      expect(
        () => LanRevision.fromJson({
          ...wire,
          'unknown': '${wire['unknown']}$suffix',
        }),
        throwsA(isA<LanSyncFailure>()),
      );
    }
  });
  test(
    'schema-only message heads merge with maximum schema deterministically',
    () {
      LanRevision message(String device, int schema) => LanRevision(
        kind: 'messages',
        id: 'm',
        vector: {device: 1},
        payload: {
          'client_schema': schema,
          'row': {'id': 'm', 'content': 'same'},
        },
      );
      final a = message('a', 18), b = message('b', 19);
      final joined = reduceLanHeads([a, b]).single;
      expect(joined.payload['client_schema'], 19);
      expect(joined.vector, {'a': 1, 'b': 1});
      expect(reduceLanHeads([b, a]).single.hash, joined.hash);
    },
  );
  test(
    'setting identity ignores schema while preserving latest field edit',
    () {
      final a = setting('a', 100, 'old');
      final original = setting('b', 200, 'new');
      final b = LanRevision(
        kind: original.kind,
        id: original.id,
        vector: original.vector,
        payload: {...original.payload, 'client_schema': 19},
      );
      final joined = reduceLanHeads([a, b]).single;
      expect(joined.payload['client_schema'], 19);
      expect(joined.payload['row']['voice_file'], 'new');
    },
  );
  test('causally later edit dominates independently of device time', () {
    final a = setting('phone', 200, 'old');
    final b = setting('mac', 100, 'causal', vector: {'phone': 1, 'mac': 1});
    expect(reduceLanHeads([a, b, a]).single.hash, b.hash);
  });
  test('concurrent setting merge is deterministic, later clear wins', () {
    final a = setting('phone', 200, 'phone'), b = setting('mac', 300, null);
    final ab = reduceLanHeads([a, b]).single,
        ba = reduceLanHeads([b, a]).single;
    expect(ab.hash, ba.hash);
    expect(ab.payload['row']['voice_file'], isNull);
    expect(ab.vector, {'phone': 1, 'mac': 1});
    expect(reduceLanHeads([a, b, ab]).single.hash, ab.hash);
  });
  test(
    'unknown settings preserve both, and concurrent delete does not resurrect',
    () {
      final a = setting('phone', 0, 'phone'), b = setting('mac', 0, 'mac');
      expect(reduceLanHeads([a, b]), hasLength(2));
      final delete = LanRevision(
        kind: a.kind,
        id: a.id,
        vector: {'mac': 1},
        payload: a.payload,
        deleted: true,
      );
      expect(reduceLanHeads([a, delete]), hasLength(2));
    },
  );
  test('concurrent raw message edits retain both full versions', () {
    LanRevision message(String device) => LanRevision(
      kind: 'messages',
      id: 'm',
      vector: {device: 1},
      payload: {
        'row': {'id': 'm', 'content': device},
      },
    );
    final heads = reduceLanHeads([message('phone'), message('mac')]);
    expect(heads.map((r) => r.payload['row']['content']).toSet(), {
      'phone',
      'mac',
    });
  });
  test('wire hash and setting times are validated before persistence', () {
    final original = setting('phone', 100, 'phone');
    expect(LanRevision.fromJson(original.toJson()).hash, original.hash);
    expect(
      () => LanRevision.fromJson({...original.toJson(), 'deleted': true}),
      throwsA(isA<LanSyncFailure>()),
    );
    final bad = LanRevision(
      kind: 'settings',
      id: 'prefs',
      vector: {'phone': 1},
      payload: {
        'storage': 'preference',
        'key': 'aicove.ui_models.v1',
        'json_value': '"not a map"',
        'setting_times_version': 1,
        'setting_times': {},
      },
    );
    expect(
      () => LanRevision.fromJson(bad.toJson()),
      throwsA(isA<LanSyncFailure>()),
    );
  });
  test('revisions carrying fields that later became device-local stay '
      'readable', () {
    // Written before frosted_tint_fill joined localGeneralSettings; rejecting
    // it made LAN initialization fail on every start.
    final legacy = LanRevision(
      kind: 'settings',
      id: 'prefs',
      vector: {'phone': 1},
      payload: {
        'storage': 'preference',
        'key': 'aicove.ui_models.v1',
        'json_value': '{"frosted_tint_fill":0.4,"model":"x"}',
        'setting_times_version': 1,
        'setting_times': {
          'frosted_tint_fill': {'at_ms': 1, 'device_id': 'phone'},
        },
      },
    );
    expect(LanRevision.fromJson(legacy.toJson()).hash, legacy.hash);
  });
}
