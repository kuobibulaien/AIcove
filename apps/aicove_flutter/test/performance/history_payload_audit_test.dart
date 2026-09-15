import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolResult;
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

// Synthetic observations of current behavior, not device frame benchmarks.
void main() {
  test('cached display still loads and decodes large unused tool results',
      () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
            id: 'synthetic',
            title: 'synthetic',
            displayName: 'synthetic',
            createdAt: 1,
            updatedAt: 1));
    final largeResult = 'x' * 2000000;
    final expected = <String>[];
    for (var i = 0; i < 20; i++) {
      final display = Message.text(
          id: 'p$i',
          role: 'assistant',
          content: 'visible $i',
          createdAt: DateTime(2026));
      expected.add(display.content);
      final payload = ChatMessageProjectionCodec.copyWithProjectedMessages(
          ChatMessageProjectionCodec.buildRawAssistantPayload(
              apiResult: ApiCallResult(
            replyText: 'visible $i',
            processedText: 'visible $i',
            pluginEvents: const [],
            toolResults: const [],
            rawToolResults: [
              ToolResult(
                  toolCallId: 'tool$i', name: 'synthetic', result: largeResult),
            ],
          )),
          [display]);
      await database.into(database.messages).insert(db.MessagesCompanion.insert(
          id: 'm$i',
          conversationId: 'synthetic',
          role: 'assistant',
          content: 'visible $i',
          createdAt: i,
          rawPayload: Value(jsonEncode(payload))));
    }
    final clock = Stopwatch()..start();
    final rows = await MessageRepository(database)
        .getByConversationStable('synthetic', limit: 21);
    final readMs = clock.elapsedMilliseconds;
    final chars = rows.fold<int>(0, (n, m) => n + (m.rawPayload?.length ?? 0));
    expect(chars, greaterThan(40000000));
    var eventLoopYielded = false;
    Timer.run(() => eventLoopYielded = true);
    clock.reset();
    final raw = rows.map((m) => MessageConverter.fromDb(m)).toList();
    final decodeMs = clock.elapsedMilliseconds;
    clock.reset();
    final display =
        const ChatFrontendMessageProjectionService().projectMessages(raw);
    final projectMs = clock.elapsedMilliseconds;
    expect(eventLoopYielded, isFalse,
        reason: 'Conversion and projection are synchronous');
    expect(display.map((m) => m.content), expected.reversed);
    expect(
        (raw.first.rawPayload!['rawToolResults'] as List)
            .first['result']
            .length,
        2000000);
    final displayOnlyRaw = raw
        .map((m) => m.copyWith(rawPayload: {
              'projectedMessages': m.rawPayload!['projectedMessages'],
            }))
        .toList();
    final reducedChars = displayOnlyRaw.fold<int>(
        0, (n, m) => n + jsonEncode(m.rawPayload).length);
    expect(
        const ChatFrontendMessageProjectionService()
            .projectMessages(displayOnlyRaw)
            .map((m) => m.content),
        display.map((m) => m.content));
    debugPrint('[HistoryPayloadAudit] rows=${rows.length} payloadChars=$chars '
        'displayOnlyChars=$reducedChars readMs=$readMs decodeMs=$decodeMs '
        'projectionMs=$projectMs eventLoopYielded=$eventLoopYielded');
    await Future<void>.delayed(Duration.zero);
    expect(eventLoopYielded, isTrue);
  });
}
