import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/features/voice_call/data/sqlite_call_record_store.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late db.AppDatabase database;
  late SqliteCallRecordStore store;

  setUp(() async {
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await database.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at) "
      "VALUES('nahida','纳西妲','纳西妲',1,1)",
    );
    store = SqliteCallRecordStore(database);
  });
  tearDown(() => database.close());

  test('archive keeps the turns inside the call bubble', () async {
    final bubbles = <Message>[];
    var ids = 0;
    final archiver = VoiceCallArchiver(
      newId: (prefix) => '${prefix}_${ids++}',
      now: () => DateTime(2026, 10, 12, 3, 4, 21),
      appendBubble: (_, bubble) async => bubbles.add(bubble),
    );
    final block = await archiver.archive(
      conversationId: 'nahida',
      connectedAt: DateTime(2026, 10, 12, 3, 1),
      turns: const [
        CallTurn(role: 'user', text: '我面完了'),
        CallTurn(role: 'assistant', text: '诶？怎么', interrupted: true),
      ],
    );

    expect(block!.duration, const Duration(minutes: 3, seconds: 21));
    final bubble = bubbles.single;
    expect(bubble.role, 'user');
    // 模型只看到标签（之后加摘要），逐句原话不进上下文。
    expect(bubble.content, '[语音通话 03:21]');
    expect(bubble.blocks!.single, same(block));
    // 记录随气泡序列化（也就随聊天同步），补摘要时不丢。
    final again =
        MessageBlock.fromJson(block.withSummary('面试结束了').toJson())
            as CallRecordBlock;
    expect(again.turns.map((t) => (t.role, t.text, t.interrupted)), [
      ('user', '我面完了', false),
      ('assistant', '诶？怎么', true),
    ]);
    expect(again.content, '[语音通话 03:21]\n通话摘要：面试结束了');
  });

  test('a call that never connected leaves no record', () async {
    final archiver = VoiceCallArchiver(
      newId: (prefix) => prefix,
      appendBubble: (_, _) async => fail('should not append'),
    );
    expect(
      await archiver.archive(
        conversationId: 'nahida',
        connectedAt: null,
        turns: const [],
      ),
      isNull,
    );
  });

  test('older calls are still read from the local tables', () async {
    await database.customStatement(
      'INSERT INTO call_sessions '
      '(id, conversation_id, started_at, ended_at, duration_ms) '
      "VALUES ('old', 'nahida', 1, 61001, 60000)",
    );
    await database.customStatement(
      'INSERT INTO call_turns (call_id, seq, role, text, interrupted) '
      "VALUES ('old', 0, 'user', '在吗', 0), ('old', 1, 'assistant', '在', 1)",
    );
    final old = await store.load('old');
    expect(old!.turns.map((t) => (t.role, t.text, t.interrupted)), [
      ('user', '在吗', false),
      ('assistant', '在', true),
    ]);
    expect(await store.load('missing'), isNull);
  });

  group('call summary', () {
    late List<Future<void>> background;
    late List<(String, String, String)> updated;

    VoiceCallArchiver archiver(
      Future<String?> Function(String, List<CallTurn>) summarize,
    ) => VoiceCallArchiver(
      newId: (prefix) => prefix,
      appendBubble: (_, _) async {},
      summarize: summarize,
      attachSummary:
          ({
            required conversationId,
            required messageId,
            required callId,
            required summary,
          }) async {
            updated.add((messageId, callId, summary));
            return true;
          },
      runInBackground: background.add,
      now: () => DateTime(2026, 10, 12, 3, 4),
    );

    setUp(() {
      background = [];
      updated = [];
    });

    test('summary is written into the bubble and survives JSON', () async {
      List<CallTurn>? seen;
      await archiver((_, turns) async {
        seen = turns;
        return '用户说面试结束了，感觉还行。';
      }).archive(
        conversationId: 'nahida',
        connectedAt: DateTime(2026, 10, 12, 3, 1),
        turns: const [CallTurn(role: 'user', text: '我面完了')],
      );
      await Future.wait(background);

      expect(seen!.single.text, '我面完了');
      // 只按消息与通话编号补摘要，不拿挂断时的旧气泡整条覆盖。
      expect(updated.single, ('call_msg', 'call', '用户说面试结束了，感觉还行。'));
    });

    test('summary is part of the block content and survives JSON', () {
      final block = CallRecordBlock(
        messageId: 'm',
        callId: 'c',
        duration: const Duration(minutes: 3),
      ).withSummary('用户说面试结束了。');
      // 模型从块内容读取，摘要必须在内容里。
      expect(block.content, '[语音通话 03:00]\n通话摘要：用户说面试结束了。');
      final again = MessageBlock.fromJson(block.toJson()) as CallRecordBlock;
      expect(again.summary, block.summary);
      expect(again.content, block.content);
    });

    test('a failed summary leaves the bubble as it was', () async {
      await archiver((_, _) async => throw StateError('offline')).archive(
        conversationId: 'nahida',
        connectedAt: DateTime(2026, 10, 12, 3, 1),
        turns: const [CallTurn(role: 'user', text: '在吗')],
      );
      await Future.wait(background);
      expect(updated, isEmpty);
    });

    test('a call where the user said nothing is not summarized', () async {
      await archiver((_, _) async => fail('should not summarize')).archive(
        conversationId: 'nahida',
        connectedAt: DateTime(2026, 10, 12, 3, 1),
        turns: const [CallTurn(role: 'assistant', text: '喂？')],
      );
      expect(background, isEmpty);
    });
  });
}
