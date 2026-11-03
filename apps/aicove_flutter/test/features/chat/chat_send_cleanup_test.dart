import 'dart:io';

import 'package:aicove_flutter/src/features/auto_reply/data/analyzer_scheduler.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => segmentedProbeSettings;
  void fail() =>
      state = AsyncError(StateError('settings failed'), StackTrace.current);
}

class _Activity extends AnalyzerScheduler {
  _Activity(super.ref);
  bool fail = false;
  @override
  Future<void> refreshFromStorage() async {}
  @override
  Future<void> handleUserMessageActivity({
    required String conversationId,
    required String? messageId,
    required DateTime occurredAt,
  }) async {
    if (fail) throw StateError('activity failed');
  }
}

class _Send extends ChatSendService {
  _Send(super.ref);
  bool failBeforeCommit = false;
  bool failAfterCommit = false;
  bool failMark = false;
  void Function()? afterCommit;
  final marked = <String>[];
  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    if (failBeforeCommit) throw StateError('persistence failed');
    await super.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
    afterCommit?.call();
    if (failAfterCommit) throw StateError('cache refresh failed after commit');
  }

  @override
  Future<void> markUserMessageFailed({
    required String convId,
    required String userMsgId,
  }) async {
    marked.add(userMsgId);
    if (failMark) throw StateError('mark failed');
    await super.markUserMessageFailed(convId: convId, userMsgId: userMsgId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  late Directory directory;
  late SegmentedChatFixture fixture;
  late _Send send;
  late _Activity activity;
  late _Settings settings;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('send_cleanup_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = oldPaths;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    fixture = await SegmentedChatFixture.create(
      historyCount: 0,
      extraOverrides: [
        appSettingsProvider.overrideWith(() => settings = _Settings()),
        chatSendServiceProvider.overrideWith((ref) => send = _Send(ref)),
        analyzerSchedulerProvider.overrideWith(
          (ref) => activity = _Activity(ref),
        ),
      ],
    );
    fixture.container.read(chatSendServiceProvider);
    fixture.container.read(analyzerSchedulerProvider);
  });
  tearDown(() => fixture.dispose());

  bool sending() => fixture.container.read(
    conversationSendingProvider(fixture.conversation.id),
  );
  Future<List<Message>> users() async =>
      (await fixture.container
              .read(chatHistoryStoreProvider)
              .loadAllRawMessages(fixture.conversation.id))
          .where((m) => m.role == 'user')
          .toList();

  test(
    'pre-commit failure rethrows without marking a nonexistent message',
    () async {
      send.failBeforeCommit = true;
      await expectLater(
        fixture.container.read(chatActionsProvider).send('draft'),
        throwsA(isA<StateError>()),
      );
      expect(sending(), isFalse);
      expect(await users(), isEmpty);
      expect(send.marked, isEmpty);
    },
  );

  for (final phase in ['activity', 'settings', 'afterCommit']) {
    test(
      '$phase failure marks committed user and always releases generation',
      () async {
        if (phase == 'activity') activity.fail = true;
        if (phase == 'settings') send.afterCommit = settings.fail;
        if (phase == 'afterCommit') send.failAfterCommit = true;
        await fixture.container.read(chatActionsProvider).send('accepted');
        expect(sending(), isFalse);
        final committed = await users();
        expect(committed, hasLength(1));
        expect(committed.single.status, 'failed');
        expect(send.marked, [committed.single.id]);
        expect(fixture.container.read(conversationErrorProvider(fixture.conversation.id)), contains('failed'));
      },
    );
  }

  test('failure while marking does not retain the generation lock', () async {
    activity.fail = true;
    send.failMark = true;
    // A secondary storage failure may propagate, but must not strand sending.
    try {
      await fixture.container.read(chatActionsProvider).send('accepted');
    } catch (_) {}
    expect(send.marked, hasLength(1));
    expect(fixture.container.read(conversationErrorProvider(fixture.conversation.id)), contains('activity failed'));
    expect(sending(), isFalse);
  });
}
