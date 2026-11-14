import 'dart:convert';

import 'package:aicove_flutter/src/core/sync/conversation_ownership.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unclaimed conversations choose the smallest known device', () async {
    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'device_b',
      'aicove.devices.v1': jsonEncode({'device_a': 'A', 'device_b': 'B'}),
    });
    final ownership = await ConversationOwnership.load();
    expect(ownership.deviceId, 'device_b');
    expect(ownership.owns('old'), isFalse);
    await ConversationOwnership.claim('old');
    expect((await ConversationOwnership.load()).owns('old'), isTrue);
  });
}
