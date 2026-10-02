import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('display read avoids duplicate audio but preserves raw truth and paging',
      () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
            id: 'c', title: 'c', displayName: 'c', createdAt: 1, updatedAt: 1));
    final audio = 'data:audio/wav;base64,${'A' * 1000000}';
    final projection = Message.fromBlocks(
        id: 'audio',
        role: 'assistant',
        createdAt: DateTime(2026),
        blocks: [AudioBlock(messageId: 'audio', url: audio, text: 'voice')]);
    final payload = jsonEncode({
      'version': 1,
      'rawReplyText': 'original',
      'toolAudioResults': [
        {'audioUrl': audio, 'text': 'voice'}
      ],
      'supplementInsertOps': [
        {'kind': 'audio', 'audioUrl': audio}
      ],
      'projectedMessages':
          ChatMessageProjectionCodec.serializeMessages([projection]),
    });
    for (var i = 0; i < 3; i++) {
      await database.into(database.messages).insert(db.MessagesCompanion.insert(
          id: 'm$i',
          conversationId: 'c',
          role: 'assistant',
          content: 'original',
          createdAt: 1,
          rawPayload: Value(payload)));
    }
    final repo = MessageRepository(database);
    final rows = await repo.getByConversationForDisplay('c', limit: 2);
    expect(rows.map((m) => m.id), ['m2', 'm1']);
    expect(rows.first.rawPayload!.length, lessThan(payload.length ~/ 2));
    expect((await repo.getByConversationStable('c')).first.rawPayload, payload);
    final older = await repo.getByConversationForDisplay('c',
        limit: 2, beforeTime: 1, beforeId: rows.last.id);
    expect(older.map((m) => m.id), ['m0']);
    final logs = <LogEntry>[];
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      frontendDiagnosticsProvider
          .overrideWithValue(FrontendDiagnosticsService(sink: logs.add)),
    ]);
    addTearDown(container.dispose);
    var yielded = false;
    Timer.run(() => yielded = true);
    final window = await container
        .read(conversationTimelineCacheProvider)
        .watchWindow(conversationId: 'c', limit: 20)
        .first;
    expect(yielded, true);
    expect(window.messages.length, 3);
    for (final m in window.messages) {
      expect(m.audios.single.url, audio);
      expect(m.audios.single.text, 'voice');
      expect(m.rawPayload, null);
    }
    final state = logs
        .singleWhere((e) =>
            e.metadata?['event'] == 'historyColdLoad' &&
            e.metadata?['phase'] == 'end')
        .metadata!['state'] as Map;
    expect(state['backgroundDecode'], true);
    expect(state['displayRead'], true);
    expect(state['displayFallbackCount'], 0);
    expect(state['payloadAudioResultChars'], 0);
    expect(state['payloadSupplementChars'], 0);
    expect(state.length, lessThanOrEqualTo(32));
    expect((await repo.getById('m2'))!.rawPayload, payload);
  });

  test('invalid cached projection falls back to original reconstruction',
      () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
            id: 'c', title: 'c', displayName: 'c', createdAt: 1, updatedAt: 1));
    for (var i = 0; i < 3; i++) {
      await database.into(database.messages).insert(db.MessagesCompanion.insert(
          id: 'm$i',
          conversationId: 'c',
          role: 'assistant',
          content: 'fallback $i',
          createdAt: i,
          rawPayload: Value(jsonEncode({
            'rawReplyText': 'fallback $i',
            'processedText': 'fallback $i',
            'projectedMessages': [
              if (i == 0) {'invalid': true} else if (i == 1) 42
            ]
          }))));
    }
    final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)]);
    addTearDown(container.dispose);
    final window = await container
        .read(conversationTimelineCacheProvider)
        .watchWindow(conversationId: 'c', limit: 20)
        .first;
    expect(window.messages.map((m) => m.content),
        ['fallback 0', 'fallback 1', 'fallback 2']);
  });
}
