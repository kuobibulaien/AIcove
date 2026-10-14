// Plan 12 B4: the role may call the user. The chat model chooses a call
// through the `call_user` tool while writing ahead; the call rings at fire
// time, a missed one leaves a bubble and two in a row pause calling.
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/incoming_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call_ledger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/voice_call/application/scripted_opening_reply_generator.dart';
import 'package:aicove_flutter/src/features/voice_call/application/voice_call_archiver.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';
import 'package:aicove_flutter/src/features/voice_call/providers/voice_call_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EchoGenerator implements CallReplyGeneratorPort {
  final calls = <List<CallTurn>>[];

  @override
  Stream<String> streamReply(List<CallTurn> turns) {
    calls.add(turns);
    return Stream.value('模型说的');
  }
}

Conversation _conversation({String persona = ''}) {
  final now = DateTime(2026, 10, 14, 9);
  return Conversation(
    id: 'c1',
    title: '理',
    displayName: '理',
    personaPrompt: persona,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('call_user tool', () {
    test('records the opening line instead of calling', () async {
      String? recorded;
      final tool = buildCallUserTool(onCall: (line) => recorded = line);

      expect(tool.name, 'call_user');
      final schema = tool.toOpenAISchema()['function'] as Map;
      expect((schema['parameters'] as Map)['required'], ['opening_line']);
      expect(await tool.handler({'opening_line': ' 喂，在干嘛呢 '}), isNotEmpty);
      expect(recorded, '喂，在干嘛呢');
    });

    test('an empty opening line is not a call', () async {
      String? recorded;
      final tool = buildCallUserTool(onCall: (line) => recorded = line);
      await tool.handler({'opening_line': '  '});
      expect(recorded, isNull);
      expect(
        openingLineFromToolCalls(const [
          ToolCall(id: 'a', name: 'other', arguments: {'opening_line': 'x'}),
          ToolCall(id: 'b', name: 'call_user', arguments: {}),
          ToolCall(
            id: 'c',
            name: 'call_user',
            arguments: {'opening_line': '在吗'},
          ),
        ]),
        '在吗',
      );
    });

    test('is offered on Android and macOS only', () {
      expect(proactiveCallsSupported(TargetPlatform.android), isTrue);
      expect(proactiveCallsSupported(TargetPlatform.macOS), isTrue);
      expect(proactiveCallsSupported(TargetPlatform.iOS), isFalse);
      expect(proactiveCallsSupported(TargetPlatform.windows), isFalse);
    });
  });

  test('the role speaks the opening line first, then the model', () async {
    final inner = _EchoGenerator();
    final generator = ScriptedOpeningReplyGenerator(inner, '  喂～是我 ');

    expect(await generator.streamReply(const []).join(), '喂～是我');
    expect(inner.calls, isEmpty);
    const turns = [CallTurn(role: 'user', text: '嗯？')];
    expect(await generator.streamReply(turns).join(), '模型说的');
    expect(await generator.streamReply(const []).join(), '模型说的');
    expect(inner.calls, hasLength(2));
  });

  group('missed calls', () {
    test('the bubble is the role\'s, with a label the model can read', () {
      final block = CallRecordBlock.missed(messageId: 'm', callId: 'call');
      expect(block.content, '[未接的语音通话]');
      final restored = MessageBlock.fromJson(block.toJson());
      expect(restored, isA<CallRecordBlock>());
      expect((restored as CallRecordBlock).missed, isTrue);
      expect(restored.duration, Duration.zero);
    });
  });

  test('a call trigger keeps its action through JSON', () {
    final trigger = AutoReplyTrigger(
      id: 't',
      title: '打个电话',
      type: AutoReplyTriggerType.delay,
      status: AutoReplyTriggerStatus.prepared,
      createdAt: DateTime(2026, 10, 14),
      nextFireAt: DateTime(2026, 10, 14, 1),
      allowNight: false,
      requireExact: false,
      delayMinutes: 60,
      manual: false,
      conversationId: 'c1',
      cachedContent: '喂',
      action: ProactiveAction.callUser,
    );
    expect(trigger.toJson()['action'], 'call_user');
    expect(
      AutoReplyTrigger.fromJson(trigger.toJson()).action,
      ProactiveAction.callUser,
    );
    final message = trigger.copyWith(action: ProactiveAction.sendMessage);
    expect(message.toJson().containsKey('action'), isFalse);
    expect(
      AutoReplyTrigger.fromJson(message.toJson()).action,
      ProactiveAction.sendMessage,
    );
  });

  group('decision facts', () {
    final now = DateTime(2026, 10, 14, 20);
    String facts({String? persona}) => ContextAnalyzer.buildDecisionState(
      assistantName: '理',
      proactiveState: ConversationProactiveState(
        conversationId: 'c1',
        lastUserAt: now.subtract(const Duration(hours: 1)),
      ),
      recent: [
        Message.text(
          id: 'm',
          role: 'user',
          content: '我去吃饭',
          createdAt: now.subtract(const Duration(hours: 1)),
        ),
      ],
      pendingTriggers: const [],
      now: now,
      callWelcomePersona: persona,
    );

    test('mention a welcome only when calls are allowed', () {
      expect(facts(), isNot(contains('允许角色主动打电话')));
      final welcome = facts(persona: '古灵精怪，爱捉弄人');
      expect(welcome, contains('允许角色主动打电话'));
      expect(welcome, contains('古灵精怪，爱捉弄人'));
    });

    test('cut the persona to 300 characters', () {
      final long = ContextAnalyzer.callWelcomePersonaOf(
        _conversation(persona: '甲' * 400),
      );
      expect(long.length, 301);
      expect(long, endsWith('…'));
      expect(ContextAnalyzer.callWelcomePersonaOf(_conversation()), '（没有写人设）');
    });
  });

  group('ProactiveCallLedger', () {
    late db.AppDatabase database;
    late ProactiveCallLedger ledger;
    final t0 = DateTime(2026, 10, 14, 9);

    setUp(() async {
      database = db.AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      ledger = ProactiveCallLedger(database);
    });

    ProactiveCall call(String id, DateTime at, {String conv = 'c1'}) =>
        ProactiveCall(
          triggerId: id,
          conversationId: conv,
          openingLine: '喂',
          rangAt: at,
          answerUntil: at.add(const Duration(seconds: 30)),
        );

    // A call whose delivery was claimed.
    Future<void> rang(ProactiveCall c) async {
      expect(await ledger.reserve(c, now: c.rangAt), isTrue);
      await ledger.confirm(c.triggerId);
    }

    test('only one call rings at a time, across roles', () async {
      expect(await ledger.reserve(call('a', t0), now: t0), isTrue);
      expect(await ledger.reserve(call('b', t0, conv: 'c2'), now: t0), isFalse);
      expect(await ledger.reserve(call('a', t0), now: t0), isFalse);
      // Past the first call's deadline the slot is free again.
      final later = t0.add(const Duration(minutes: 1));
      expect(await ledger.reserve(call('b', later), now: later), isTrue);
    });

    test('a call leaves ringing once and is settled once', () async {
      await rang(call('a', t0));
      expect(await ledger.miss('a', now: t0), isTrue);
      expect(await ledger.answer('a', now: t0), isFalse);
      expect(await ledger.miss('a', now: t0), isFalse);
      expect((await ledger.unsettledMissed()).single.triggerId, 'a');
      await ledger.markSettled('a');
      expect(await ledger.unsettledMissed(), isEmpty);
    });

    test('a call past its deadline can no longer be answered', () async {
      await rang(call('a', t0));
      final late = t0.add(const Duration(seconds: 30));
      expect(await ledger.answer('a', now: late), isFalse);
      expect(await ledger.answer('a', now: t0), isTrue);
    });

    test('a table from before confirmation gets the column', () async {
      final old = db.AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (raw) => raw
            ..execute(
              'CREATE TABLE proactive_calls (trigger_id TEXT NOT NULL '
              'PRIMARY KEY, conversation_id TEXT NOT NULL, opening_line TEXT '
              'NOT NULL, rang_at INTEGER NOT NULL, answer_until INTEGER NOT '
              'NULL, state TEXT NOT NULL, settled_at INTEGER)',
            )
            ..execute(
              "INSERT INTO proactive_calls VALUES ('a', 'c1', '喂', "
              '${t0.millisecondsSinceEpoch}, '
              "${t0.add(const Duration(seconds: 30)).millisecondsSinceEpoch}, "
              "'ringing', NULL)",
            ),
        ),
      );
      addTearDown(old.close);
      final oldLedger = ProactiveCallLedger(old);
      expect((await oldLedger.ringing(now: t0))!.triggerId, 'a');
      final later = t0.add(const Duration(minutes: 1));
      expect(await oldLedger.reserve(call('b', later), now: later), isTrue);
      expect(await oldLedger.ringing(now: later), isNull);
    });

    test('a call never confirmed is dropped, not missed', () async {
      await ledger.reserve(call('a', t0), now: t0);
      expect(await ledger.ringing(now: t0), isNull);
      expect(await ledger.answer('a', now: t0), isFalse);
      await ledger.expire(now: t0.add(const Duration(seconds: 30)));
      expect(await ledger.unsettledMissed(), isEmpty);
      expect(await ledger.find('a'), isNull);
    });

    test('an unanswered call expires at its deadline', () async {
      await rang(call('a', t0));
      expect(await ledger.nextDeadline(), t0.add(const Duration(seconds: 30)));
      await ledger.expire(now: t0.add(const Duration(seconds: 10)));
      expect(await ledger.unsettledMissed(), isEmpty);
      await ledger.expire(now: t0.add(const Duration(seconds: 30)));
      expect((await ledger.unsettledMissed()).single.triggerId, 'a');
      expect(await ledger.nextDeadline(), isNull);
    });

    test('two missed in a row pause calling until the user writes', () async {
      Future<void> missed(String id, DateTime at) async {
        await rang(call(id, at));
        await ledger.miss(id);
      }

      await missed('a', t0);
      expect(await ledger.callsPaused('c1'), isFalse);
      await missed('b', t0.add(const Duration(hours: 1)));
      expect(await ledger.callsPaused('c1'), isTrue);
      expect(await ledger.callsPaused('c2'), isFalse);

      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: 'c1',
              title: '理',
              displayName: '理',
              createdAt: 0,
              updatedAt: 0,
            ),
          );
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'm',
              conversationId: 'c1',
              role: 'user',
              content: '刚才在忙',
              createdAt: t0
                  .add(const Duration(hours: 2))
                  .millisecondsSinceEpoch,
            ),
          );
      expect(await ledger.callsPaused('c1'), isFalse);
    });

    test('an answered call clears the pause', () async {
      for (final (id, hours) in [('a', 0), ('b', 1)]) {
        final at = t0.add(Duration(hours: hours));
        await rang(call(id, at));
        await ledger.miss(id);
      }
      final at = t0.add(const Duration(hours: 2));
      await rang(call('c', at));
      await ledger.answer('c', now: at);
      expect(await ledger.callsPaused('c1'), isFalse);
    });

    test('calls nobody moved past their deadline count as missed', () async {
      // The app was killed: both calls still read `ringing`.
      for (final (id, hours) in [('a', 0), ('b', 1)]) {
        final at = t0.add(Duration(hours: hours));
        await rang(call(id, at));
      }
      final during = t0.add(const Duration(hours: 1, seconds: 10));
      expect(await ledger.callsPaused('c1', now: during), isFalse);
      final after = t0.add(const Duration(hours: 2));
      expect(await ledger.callsPaused('c1', now: after), isTrue);
    });
  });

  group('IncomingCallNotifier', () {
    late ProviderContainer container;
    late List<Message> bubbles;
    late ProactiveCallLedger ledger;
    var failWrites = 0;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      bubbles = [];
      failWrites = 0;
      var ids = 0;
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          voiceCallArchiverProvider.overrideWithValue(
            VoiceCallArchiver(
              newId: (prefix) => '${prefix}_${ids++}',
              appendBubble: (_, _) async {},
              appendAssistantBubble: (_, bubble) async {
                if (failWrites-- > 0) throw StateError('disk full');
                bubbles.add(bubble);
              },
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      ledger = container.read(proactiveCallLedgerProvider);
    });

    Future<IncomingCall> ring(String id, Duration ringFor) async {
      final now = DateTime.now();
      await ledger.reserve(
        ProactiveCall(
          triggerId: id,
          conversationId: 'c1',
          openingLine: '喂，在干嘛',
          rangAt: now,
          answerUntil: now.add(ringFor),
        ),
      );
      await ledger.confirm(id);
      final call = IncomingCall(
        conversation: _conversation(),
        openingLine: '喂，在干嘛',
        triggerId: id,
      );
      container
          .read(incomingCallProvider.notifier)
          .show(call, until: now.add(ringFor));
      return call;
    }

    test('shows one call at a time', () async {
      final notifier = container.read(incomingCallProvider.notifier);
      final first = await ring('t1', const Duration(seconds: 30));
      expect(notifier.busy, isTrue);
      expect(notifier.show(first, until: DateTime.now()), isFalse);
      notifier.dismiss();
    });

    test('declining leaves exactly one missed call', () async {
      final notifier = container.read(incomingCallProvider.notifier);
      await ring('t1', const Duration(seconds: 30));
      await notifier.decline();
      await notifier.decline();
      await container.read(proactiveCallSettlerProvider).settle();

      expect(container.read(incomingCallProvider), isNull);
      expect(bubbles.single.role, 'assistant');
      expect(bubbles.single.blocks!.single, isA<CallRecordBlock>());
      expect((await ledger.find('t1'))!.state, ProactiveCallState.missed);
    });

    test('a failed bubble write is retried as the same bubble', () async {
      final notifier = container.read(incomingCallProvider.notifier);
      final settler = container.read(proactiveCallSettlerProvider);
      await ring('t1', const Duration(seconds: 30));
      failWrites = 1;
      await notifier.decline();
      expect(bubbles, isEmpty);
      expect((await ledger.unsettledMissed()).single.triggerId, 't1');

      await settler.settle();
      await settler.settle();
      expect(bubbles.single.id, 'call_msg_missed_t1');
      expect(await ledger.unsettledMissed(), isEmpty);
    });

    test('not picking up in time counts as missed', () async {
      await ring('t1', const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(container.read(incomingCallProvider), isNull);
      expect(bubbles, hasLength(1));
    });

    test('a call missed elsewhere cannot be answered', () async {
      await ring('t1', const Duration(seconds: 30));
      await ledger.miss('t1');

      expect(
        await container.read(incomingCallProvider.notifier).accept(),
        isNull,
      );
      expect(container.read(activeVoiceCallProvider), isNull);
    });
  });
}
