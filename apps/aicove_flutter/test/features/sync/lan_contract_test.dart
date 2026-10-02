import 'package:flutter_test/flutter_test.dart';
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
        'json_value': '{"ui_scale_factor":2}',
        'setting_times_version': 1,
        'setting_times': {},
      },
    );
    expect(
      () => LanRevision.fromJson(bad.toJson()),
      throwsA(isA<LanSyncFailure>()),
    );
  });
}
