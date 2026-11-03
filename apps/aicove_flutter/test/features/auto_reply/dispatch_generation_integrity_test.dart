import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_claim_store.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_dispatch_service.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger_storage.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_reply_generator.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Generator extends ProactiveReplyGenerator {
  _Generator(super.ref, this.entered, this.release);
  final Completer<void> entered;
  final Completer<void> release;
  @override
  Future<String> generate({
    required Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) async {
    entered.complete();
    await release.future;
    return '迟到的主动问候';
  }
}

class _CountingSend extends ChatSendService {
  _CountingSend(super.ref);
  int projections = 0;
  Future<void> Function()? beforeProjection;
  @override
  Future<ApiCallResult> processAssistantReplyWithPlugins({
    required Conversation conv,
    required String rawReplyText,
  }) async {
    projections++;
    await beforeProjection?.call();
    return super.processAssistantReplyWithPlugins(
      conv: conv,
      rawReplyText: rawReplyText,
    );
  }
}

class _PausingConversations extends ConversationRepository {
  _PausingConversations(super.db);
  int lookups = 0;
  int? pauseOnLookup;
  Future<void> Function()? pause;
  @override
  Future<db.Conversation?> getById(String id) async {
    if (++lookups == pauseOnLookup && pause != null) {
      final action = pause!;
      pause = null;
      await action();
    }
    return super.getById(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SegmentedChatFixture fixture;
  late Completer<void> entered;
  late Completer<void> release;
  late Directory directory;
  final oldPaths = PathProviderPlatform.instance;
  final storage = AutoReplyTriggerStorage();

  setUpAll(() async {
    final output = await Directory(
      'build/dispatch_generation_integrity',
    ).create(recursive: true);
    directory = await output.createTemp();
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    entered = Completer<void>();
    release = Completer<void>();
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        chatSendServiceProvider.overrideWith((ref) => _CountingSend(ref)),
        proactiveReplyGeneratorProvider.overrideWith(
          (ref) => _Generator(ref, entered, release),
        ),
        conversationRepositoryProvider.overrideWith(
          (ref) => _PausingConversations(ref.watch(databaseProvider)),
        ),
      ],
    );
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await fixture.dispose();
  });

  AutoReplyTrigger trigger() => AutoReplyTrigger(
    id: 'trigger',
    title: '主动问候',
    type: AutoReplyTriggerType.delay,
    status: AutoReplyTriggerStatus.pending,
    createdAt: DateTime.now(),
    nextFireAt: DateTime.now(),
    allowNight: true,
    requireExact: false,
    delayMinutes: 0,
    manual: true,
    conversationId: fixture.conversation.id,
  );

  for (final invalidation in [
    'delete_conversation',
    'delete_trigger',
    'pause_trigger',
    'expire_trigger',
  ]) {
    test('生成期间 $invalidation，生成结束不写入消息', () async {
      final original = trigger();
      await storage.saveTriggers([original]);
      final token = await AutoReplyClaimStore(fixture.database).tryClaim(
        triggerId: original.id,
        claimedBy: AutoReplyClaimOwner.foreground,
      );
      final sending = fixture.container
          .read(autoReplyDispatchServiceProvider)
          .dispatchTrigger(original, claimToken: token);
      await entered.future.timeout(const Duration(seconds: 10));
      if (invalidation == 'delete_conversation') {
        final now = DateTime.now().millisecondsSinceEpoch;
        await fixture.container
            .read(conversationRepositoryProvider)
            .softDelete(fixture.conversation.id, now, now + 1000);
      } else {
        final status = switch (invalidation) {
          'pause_trigger' => AutoReplyTriggerStatus.paused,
          'expire_trigger' => AutoReplyTriggerStatus.expired,
          _ => AutoReplyTriggerStatus.deleted,
        };
        await storage.saveTriggers([original.copyWith(status: status)]);
      }
      release.complete();
      final result = await sending;
      expect(result.success, isFalse);
      expect(result.retryable, isFalse);
      expect(
        (fixture.container.read(chatSendServiceProvider) as _CountingSend)
            .projections,
        0,
      );
      expect(
        await fixture.container
            .read(messageRepositoryProvider)
            .getAllByConversationOrderedStable(fixture.conversation.id),
        isEmpty,
      );
    });
  }

  test('lost claim never runs delivery processors', () async {
    final original = trigger();
    await storage.saveTriggers([original]);
    final claims = AutoReplyClaimStore(fixture.database);
    await claims.tryClaim(triggerId: original.id, claimedBy: 'other');
    final sending = fixture.container
        .read(autoReplyDispatchServiceProvider)
        .dispatchTrigger(original, claimToken: 'stale-token');
    await entered.future;
    release.complete();
    expect((await sending).reason, AutoReplyDispatchResult.supersededReason);
    expect(
      (fixture.container.read(chatSendServiceProvider) as _CountingSend)
          .projections,
      0,
    );
  });

  for (final fail in [false, true]) {
    test('delivery is claimed before processors (failure: $fail)', () async {
      final original = trigger();
      await storage.saveTriggers([original]);
      final claims = AutoReplyClaimStore(fixture.database);
      final token = await claims.tryClaim(
        triggerId: original.id,
        claimedBy: 'test',
      );
      final send =
          fixture.container.read(chatSendServiceProvider) as _CountingSend;
      send.beforeProjection = () async {
        expect(
          await claims.stateOf(original.id),
          isA<AutoReplyClaimDelivered>(),
        );
        if (fail) throw StateError('response factory failed');
      };
      final sending = fixture.container
          .read(autoReplyDispatchServiceProvider)
          .dispatchTrigger(original, claimToken: token);
      await entered.future;
      release.complete();
      final result = await sending;
      expect(send.projections, 1);
      expect(result.success, !fail);
      expect(result.retryable, isFalse);
      final claim =
          await claims.stateOf(original.id) as AutoReplyClaimDelivered;
      if (fail) {
        expect(claim.messageId, isNull);
      } else {
        final messages = await fixture.container
            .read(messageRepositoryProvider)
            .getAllByConversationOrderedStable(fixture.conversation.id);
        expect(messages.single.id, claim.messageId);
      }
    });
  }

  test('写入前检查通过后、发布前被暂停，不写入消息', () async {
    final original = trigger();
    await storage.saveTriggers([original]);
    final token = await AutoReplyClaimStore(fixture.database).tryClaim(
      triggerId: original.id,
      claimedBy: AutoReplyClaimOwner.foreground,
    );
    final repository =
        fixture.container.read(conversationRepositoryProvider)
            as _PausingConversations;
    // The first lookup after generation is the pre-check; pause right after
    // it, before the raw message is published.
    repository.pauseOnLookup = 2;
    repository.pause = () => storage.saveTriggers([
      original.copyWith(status: AutoReplyTriggerStatus.paused),
    ]);
    final sending = fixture.container
        .read(autoReplyDispatchServiceProvider)
        .dispatchTrigger(original, claimToken: token);
    await entered.future.timeout(const Duration(seconds: 10));
    repository.lookups = 0;
    release.complete();
    final result = await sending;
    expect(repository.pause, isNull);
    expect(result.success, isFalse);
    expect(
      await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(fixture.conversation.id),
      isEmpty,
    );
  });

  test('未持久化的表单试发仍能发送', () async {
    final sending = fixture.container
        .read(autoReplyDispatchServiceProvider)
        .dispatchTestTrigger(trigger());
    await entered.future.timeout(const Duration(seconds: 10));
    release.complete();
    expect((await sending).success, isTrue);
    expect(
      (fixture.container.read(chatSendServiceProvider) as _CountingSend)
          .projections,
      1,
    );
    expect(
      await fixture.container
          .read(messageRepositoryProvider)
          .getAllByConversationOrderedStable(fixture.conversation.id),
      hasLength(1),
    );
  });
}
