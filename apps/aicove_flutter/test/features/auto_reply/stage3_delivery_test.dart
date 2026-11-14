import 'dart:convert';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_dispatch_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/incoming_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as chat;
import '../../../tool/chat_segmented_fixture.dart';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/repositories/conversation_repository.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_call_ledger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_owner_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

const _triggerKey = 'aicove.auto_triggers.v1';
const _conv = 'conv_bg';
const _trigger = 't_bg';

Map<String, Object?> _triggerJson() => {
  'id': _trigger,
  'title': '早安',
  'type': 'custom',
  'status': 'pending',
  'created_at': DateTime.now().toIso8601String(),
  'next_fire_at': DateTime.now().toIso8601String(),
  'allow_night': true,
  'prompt': '问候一下',
  'cached_content': '早上好呀',
  'prepared_at': DateTime.now().toIso8601String(),
  'conversation_id': _conv,
};

/// A connection closed a moment ago may still hold the file in drift's
/// background isolate; retry the helper's own open on a lock.
Future<T> _withDb<T>(Future<T> Function(AppDatabase db) body) async {
  for (var attempt = 0; ; attempt++) {
    final db = AppDatabase();
    try {
      return await body(db);
    } catch (e) {
      final locked = '$e'.contains('(code 5)') || '$e'.contains('(code 6)');
      if (!locked || attempt >= 6) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 50 * (1 << attempt)));
    } finally {
      await db.close();
    }
  }
}

Future<List<Message>> _messages() => _withDb(
  (db) => (db.select(
    db.messages,
  )..where((m) => m.conversationId.equals(_conv))).get(),
);

Future<int> _unread() => _withDb(
  (db) async => (await (db.select(
    db.conversations,
  )..where((c) => c.id.equals(_conv))).getSingle()).unreadCount,
);

Future<String?> _status() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final list = jsonDecode(prefs.getString(_triggerKey)!) as List;
  return (list.single as Map)['status'] as String?;
}

class _Generator extends ProactiveReplyGenerator {
  _Generator(super.ref, this.generateReply);
  final Future<String> Function(String? reminder) generateReply;
  @override
  Future<String> generate({
    required chat.Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) => generateReply(reminder);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('background', () {
    late Directory root;
    late PathProviderPlatform oldPaths;

    setUp(() async {
      root = await (await Directory(
        'build/stage3_delivery',
      ).create(recursive: true)).createTemp();
      oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferences.setMockInitialValues({
        _triggerKey: jsonEncode([_triggerJson()]),
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      await _withDb(
        (db) => db
            .into(db.conversations)
            .insert(
              ConversationsCompanion.insert(
                id: _conv,
                title: '理',
                displayName: '理',
                createdAt: now,
                updatedAt: now,
              ),
            ),
      );
    });

    tearDown(() async {
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    });

    Map<String, dynamic> task() => {
      'triggerId': _trigger,
      'convId': _conv,
      'prompt': '问候一下',
      'characterName': '理',
    };

    test(
      'cache older than six hours is not sent when live generation is unavailable',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _triggerKey,
          jsonEncode([
            {
              ..._triggerJson(),
              'prepared_at': DateTime.now()
                  .subtract(const Duration(hours: 7))
                  .toIso8601String(),
            },
          ]),
        );
        await expectLater(runActiveReplyTaskForTest(task()), throwsStateError);
        expect(await _messages(), isEmpty);
        expect(await _status(), 'pending');
      },
    );

    test('disabled scheduler plugin cancels cached delivery', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _triggerKey,
        jsonEncode([
          {..._triggerJson(), 'source': 'aiScheduler'},
        ]),
      );
      await _withDb(
        (db) => db.customStatement(
          "UPDATE conversations SET enabled_plugins = '[]' WHERE id = ?",
          [_conv],
        ),
      );
      await runActiveReplyTaskForTest(task());
      expect(await _messages(), isEmpty);
      expect(await _unread(), 0);
      expect(await _status(), 'expired');
    });

    test(
      'interrupted confirmed call is recovered as fired without a message',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _triggerKey,
          jsonEncode([
            {..._triggerJson(), 'action': 'call_user'},
          ]),
        );
        final past = DateTime.now().subtract(const Duration(minutes: 30));
        await _withDb((db) async {
          final store = AutoReplyClaimStore(db);
          final token = await store.tryClaim(
            triggerId: _trigger,
            claimedBy: AutoReplyClaimOwner.background,
            now: past,
          );
          await store.beginDelivery(_trigger, token!, now: past);
          final ledger = ProactiveCallLedger(db);
          await ledger.reserve(
            ProactiveCall(
              triggerId: _trigger,
              conversationId: _conv,
              openingLine: '你好',
              rangAt: past,
              answerUntil: past.add(const Duration(minutes: 1)),
            ),
            now: past,
          );
          await ledger.confirm(_trigger);
        });
        await runActiveReplyTaskForTest(task());
        expect(await _messages(), isEmpty);
        expect(await _status(), 'fired');
      },
    );

    for (final age in [
      const Duration(hours: 2),
      const Duration(hours: 6, minutes: 1),
    ]) {
      test(
        'live generation failure only falls back within six hours ($age)',
        () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            _triggerKey,
            jsonEncode([
              {
                ..._triggerJson(),
                'prepared_at': DateTime.now().subtract(age).toIso8601String(),
              },
            ]),
          );
          final result = await backgroundTaskResultForTest(
            () => runActiveReplyTaskForTest({
              ...task(),
              'apiKey': 'test-key',
            }, generate: (_) async => throw StateError('network failure')),
          );
          expect(result, age.inHours < 6);
          expect(await _messages(), age.inHours < 6 ? hasLength(1) : isEmpty);
          expect(await _status(), age.inHours < 6 ? 'fired' : 'pending');
        },
      );
    }

    for (final prompt in [null, '  ', '最新提醒']) {
      test(
        'latest persisted reminder wins over stale task prompt ($prompt)',
        () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            _triggerKey,
            jsonEncode([
              {..._triggerJson(), 'prompt': prompt, 'cached_content': null},
            ]),
          );
          String? received;
          await runActiveReplyTaskForTest(
            {...task(), 'apiKey': 'test-key', 'prompt': '旧任务内容'},
            generate: (reminder) async {
              received = reminder;
              return '即时回复';
            },
          );
          expect(received, prompt == '最新提醒' ? prompt : '早安');
          expect((await _messages()).single.content, '即时回复');
        },
      );
    }

    for (final invalidation in ['pause', 'delete', 'plugin', 'owner', 'user']) {
      test('background call final gate rejects $invalidation', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _triggerKey,
          jsonEncode([
            {
              ..._triggerJson(),
              'action': 'call_user',
              'source': 'aiScheduler',
              'manual': false,
            },
          ]),
        );
        await prefs.setString(
          'aicove.ui_models.v1',
          jsonEncode({
            'auto_reply_settings': {'allow_proactive_calls': true},
          }),
        );
        var reached = false;
        await runActiveReplyTaskForTest(
          task(),
          beforeCallConfirm: () async {
            reached = true;
            if (invalidation == 'pause') {
              await prefs.setString(
                _triggerKey,
                jsonEncode([
                  {
                    ..._triggerJson(),
                    'action': 'call_user',
                    'status': 'paused',
                    'source': 'aiScheduler',
                  },
                ]),
              );
            } else if (invalidation == 'owner') {
              await prefs.setString(
                proactiveOwnerDevicesKey,
                jsonEncode({
                  _conv: {'device_id': 'other-device'},
                }),
              );
            } else {
              await _withDb((db) async {
                if (invalidation == 'delete') {
                  await db.customStatement(
                    'UPDATE conversations SET deleted_at=1 WHERE id=?',
                    [_conv],
                  );
                } else if (invalidation == 'plugin') {
                  await db.customStatement(
                    "UPDATE conversations SET enabled_plugins='[]' WHERE id=?",
                    [_conv],
                  );
                } else {
                  await db
                      .into(db.messages)
                      .insert(
                        MessagesCompanion.insert(
                          id: 'new-user',
                          conversationId: _conv,
                          role: 'user',
                          content: '刚回复',
                          createdAt: DateTime.now().millisecondsSinceEpoch,
                        ),
                      );
                }
              });
            }
          },
        );
        expect(reached, isTrue);
        expect(
          await _withDb((db) => ProactiveCallLedger(db).isConfirmed(_trigger)),
          isFalse,
        );
        expect(
          (await _messages()).where((m) => m.role == 'assistant'),
          isEmpty,
        );
        expect(await _status(), isNot('fired'));
      });
    }

    test(
      'database persistence failure returns false and releases the claim for retry',
      () async {
        final result = await backgroundTaskResultForTest(
          () => runActiveReplyTaskForTest(
            task(),
            beforePersist: () async {
              await _withDb(
                (db) => db.customStatement(
                  'INSERT INTO missing_stage3_table VALUES (1)',
                ),
              );
            },
          ),
        );
        expect(result, isFalse);
        expect(await _messages(), isEmpty);
        expect(await _status(), 'pending');
        expect(
          await _withDb((db) => AutoReplyClaimStore(db).stateOf(_trigger)),
          isA<AutoReplyClaimFree>(),
        );
        await runActiveReplyTaskForTest(task());
        expect(await _messages(), hasLength(1));
        expect(await _status(), 'fired');
      },
    );

    test('final message transaction rechecks plugin permissions', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _triggerKey,
        jsonEncode([
          {..._triggerJson(), 'source': 'aiScheduler'},
        ]),
      );
      await runActiveReplyTaskForTest(
        task(),
        beforePersist: () async {
          await _withDb(
            (db) => db.customStatement(
              "UPDATE conversations SET enabled_plugins='[]' WHERE id=?",
              [_conv],
            ),
          );
        },
      );
      expect(await _messages(), isEmpty);
      expect(await _status(), 'expired');
    });

    test('user reply during delivery keeps the new active session', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _triggerKey,
        jsonEncode([
          {..._triggerJson(), 'source': 'aiScheduler'},
        ]),
      );
      final stateStorage = ConversationProactiveStateStorage();
      await stateStorage.saveStates({
        _conv: const ConversationProactiveState(
          conversationId: _conv,
          unrepliedCount: 1,
          pendingAutoTriggerId: _trigger,
        ),
      });
      await runActiveReplyTaskForTest(
        task(),
        afterPersist: () async {
          final now = DateTime.now();
          await _withDb(
            (db) => db
                .into(db.messages)
                .insert(
                  MessagesCompanion.insert(
                    id: 'during-send',
                    conversationId: _conv,
                    role: 'user',
                    content: '我回来啦',
                    createdAt: now.millisecondsSinceEpoch,
                  ),
                ),
          );
          await stateStorage.saveStates({
            _conv: const ConversationProactiveState(
              conversationId: _conv,
            ).markUserMessage(messageId: 'during-send', occurredAt: now),
          });
        },
      );
      final current = (await stateStorage.loadStates())[_conv]!;
      expect(current.mode, ConversationProactiveMode.active);
      expect(current.unrepliedCount, 0);
      expect(current.lastUserMessageId, 'during-send');
      expect(await _status(), 'fired');
    });

    test(
      'successful scheduler delivery advances an initially empty state map',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _triggerKey,
          jsonEncode([
            {..._triggerJson(), 'source': 'aiScheduler'},
          ]),
        );
        await runActiveReplyTaskForTest(task());
        final current = (await ConversationProactiveStateStorage()
            .loadStates())[_conv]!;
        expect(current.mode, ConversationProactiveMode.silent);
        expect(current.unrepliedCount, 1);
      },
    );
  });
  group('foreground', () {
    late SegmentedChatFixture fixture;
    late Directory directory;
    late PathProviderPlatform previousPaths;
    late Future<String> Function(String?) generate;
    late Future<String?> Function() callGate;
    final storage = AutoReplyTriggerStorage();
    setUp(() async {
      directory = await (await Directory(
        'build/stage3_delivery_foreground',
      ).create(recursive: true)).createTemp();
      previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      generate = (_) async => '新鲜生成';
      callGate = () async => null;
      fixture = await SegmentedChatFixture.create(
        historyCount: 0,
        extraOverrides: [
          proactiveReplyGeneratorProvider.overrideWith(
            (ref) => _Generator(ref, (reminder) => generate(reminder)),
          ),
          proactiveCallGateProvider.overrideWith(
            (ref) =>
                (_) => callGate(),
          ),
        ],
      );
    });
    tearDown(() async {
      await fixture.dispose();
      PathProviderPlatform.instance = previousPaths;
      await directory.delete(recursive: true);
    });
    AutoReplyTrigger trigger({
      String? prompt,
      Duration age = Duration.zero,
      ProactiveAction action = ProactiveAction.sendMessage,
    }) => AutoReplyTrigger(
      id: 'foreground',
      title: '记得吃饭',
      type: AutoReplyTriggerType.delay,
      status: AutoReplyTriggerStatus.pending,
      createdAt: DateTime.now(),
      nextFireAt: DateTime.now(),
      allowNight: true,
      requireExact: false,
      delayMinutes: 0,
      manual: true,
      conversationId: fixture.conversation.id,
      prompt: prompt,
      cachedContent: '缓存文案',
      preparedAt: DateTime.now().subtract(age),
      action: action,
      source: TriggerSource.aiScheduler,
    );
    Future<AutoReplyDispatchResult> dispatch(AutoReplyTrigger item) async {
      await storage.saveTriggers([item]);
      final token = await AutoReplyClaimStore(
        fixture.database,
      ).tryClaim(triggerId: item.id, claimedBy: AutoReplyClaimOwner.foreground);
      return fixture.container
          .read(autoReplyDispatchServiceProvider)
          .dispatchTrigger(item, claimToken: token);
    }

    for (final age in [const Duration(hours: 2), const Duration(hours: 7)]) {
      test('live failure only uses a six-hour fallback ($age)', () async {
        generate = (_) async => throw StateError('live failed');
        final result = await dispatch(trigger(age: age));
        expect(result.success, age.inHours < 6);
        expect(result.retryable, age.inHours > 6);
        final messages = await fixture.database
            .select(fixture.database.messages)
            .get();
        expect(messages, age.inHours < 6 ? isNotEmpty : isEmpty);
      });
    }
    test('delivered message counts as unread, skipped one does not', () async {
      Future<int> unread() async => (await (fixture.database.select(
        fixture.database.conversations,
      )..where((c) => c.id.equals(fixture.conversation.id))).getSingle())
          .unreadCount;
      final stale = fixture.container
          .read(conversationsProvider)
          .value!
          .firstWhere((c) => c.id == fixture.conversation.id);
      expect((await dispatch(trigger())).success, isTrue);
      expect(await unread(), 1);
      // A row written back from an older in-memory copy keeps the count.
      await ConversationRepository(fixture.database).upsert(
        ConversationConverter.toCompanion(
          stale.copyWith(isPinned: !stale.isPinned),
        ),
      );
      expect(await unread(), 1);
      generate = (_) async => throw StateError('live failed');
      expect(
        (await dispatch(trigger(age: const Duration(hours: 7)))).success,
        isFalse,
      );
      expect(await unread(), 1);
    });
    for (final prompt in [null, '  ', '最新内容']) {
      test('empty reminder falls back to title ($prompt)', () async {
        String? reminder;
        generate = (value) async {
          reminder = value;
          return '即时回复';
        };
        final result = await dispatch(
          trigger(prompt: prompt, age: const Duration(hours: 2)),
        );
        expect(result.success, isTrue);
        expect(reminder, prompt == '最新内容' ? prompt : '记得吃饭');
      });
    }
    for (final invalidation in ['pause', 'delete', 'plugin', 'owner']) {
      test(
        'call rechecks current state after async gate ($invalidation)',
        () async {
          final item = trigger(action: ProactiveAction.callUser);
          var checked = false;
          callGate = () async {
            checked = true;
            if (invalidation == 'pause') {
              await storage.saveTriggers([
                item.copyWith(status: AutoReplyTriggerStatus.paused),
              ]);
            } else if (invalidation == 'owner') {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(
                proactiveOwnerDevicesKey,
                jsonEncode({
                  item.conversationId: {'device_id': 'other-device'},
                }),
              );
            } else {
              await fixture.database.customStatement(
                invalidation == 'delete'
                    ? 'UPDATE conversations SET deleted_at=1 WHERE id=?'
                    : "UPDATE conversations SET enabled_plugins='[]' WHERE id=?",
                [item.conversationId],
              );
            }
            return null;
          };
          final result = await dispatch(item);
          expect(checked, isTrue);
          expect(result.success, isFalse);
          expect(result.retryable, isFalse);
          expect(fixture.container.read(incomingCallProvider), isNull);
          expect(
            await fixture.container
                .read(proactiveCallLedgerProvider)
                .isConfirmed(item.id),
            isFalse,
          );
          expect(
            await fixture.database.select(fixture.database.messages).get(),
            isEmpty,
          );
        },
      );
    }
    test(
      'ledger confirmation survives a missed call for crash recovery',
      () async {
        final ledger = fixture.container.read(proactiveCallLedgerProvider);
        final now = DateTime.now();
        final call = ProactiveCall(
          triggerId: 'confirmed',
          conversationId: fixture.conversation.id,
          openingLine: '喂',
          rangAt: now,
          answerUntil: now.add(const Duration(minutes: 1)),
        );
        expect(await ledger.isConfirmed(call.triggerId), isFalse);
        await ledger.reserve(call);
        expect(await ledger.isConfirmed(call.triggerId), isFalse);
        await ledger.confirm(call.triggerId);
        await ledger.miss(call.triggerId);
        expect(await ledger.isConfirmed(call.triggerId), isTrue);
      },
    );
  });
}
