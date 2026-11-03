import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_approvals.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/assistant/widgets/assistant_activity_panel.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/assistant/assistant_onboarding_test.dart'
    show FakeSettings, deepSeek, settingsWith;

JournalEntry _change(String id, String description, DateTime at) =>
    JournalEntry(
      id: id,
      toolName: 'aicove_update_role',
      change: ReversibleChange(
        kind: 'assistant.role',
        description: description,
        before: const {},
        after: const {},
      ),
      createdAt: at,
    );

final _entry = _change('chg_1', '改了「小理」的人设提示词', DateTime(2026, 10, 17));
final _second = _change(
  'chg_2',
  '开启了预设「v1.3.1」的提示词条目「色彩」',
  DateTime(2026, 10, 17, 0, 1),
);

class _Journal extends FileChangeJournal {
  _Journal() : super(file: () async => File('unused'), appliers: const {});

  final undone = <String>[];

  @override
  Future<Map<String, String>> undoAll(List<String> entryIds) async {
    undone.addAll(entryIds);
    return const {};
  }
}

void main() {
  test('the latest run holds the changes made after the last user message', () {
    final older = _change('chg_0', '旧改动', DateTime(2026, 10, 16));
    final changes = [_second, _entry, older];
    expect(AssistantActivityPanel.latestRun(changes, DateTime(2026, 10, 17)), [
      _second,
      _entry,
    ]);
    expect(AssistantActivityPanel.latestRun(changes, null), isEmpty);
  });

  testWidgets(
    'the run is read from the panel\'s own chat, not the active one',
    (tester) async {
      Message user(String chat, DateTime at) =>
          Message(id: '$chat-user', role: 'user', content: 'hi', createdAt: at);
      final container = ProviderContainer(
        overrides: [
          // Another chat is active and its user wrote after the run's change.
          activeConversationProvider.overrideWithValue(
            Conversation(
              id: 'other',
              title: 'other',
              displayName: 'other',
              createdAt: DateTime(2026, 10),
            updatedAt: DateTime(2026, 10),
            ),
          ),
          conversationMessagesProvider('other').overrideWithValue(
            AsyncValue.data([user('other', DateTime(2026, 10, 18))]),
          ),
          conversationMessagesProvider('assistant').overrideWithValue(
            AsyncValue.data([user('assistant', DateTime(2026, 10, 16))]),
          ),
          assistantRecentChangesProvider.overrideWith((ref) async => [_entry]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: const Scaffold(
              body: AssistantActivityPanel(conversationId: 'assistant'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本轮改动 1 项'), findsOneWidget);
    },
  );

  testWidgets('no summary while a reply is running', (tester) async {
    final container = ProviderContainer(
      overrides: [
        conversationSendingProvider('assistant').overrideWith((ref) => true),
        assistantRunStartProvider(
          'assistant',
        ).overrideWithValue(DateTime(2026, 10, 17)),
        assistantRecentChangesProvider.overrideWith((ref) async => [_entry]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(
            body: AssistantActivityPanel(conversationId: 'assistant'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本轮改动'), findsNothing);
  });

  testWidgets('approval cards answer the run; changes can be undone', (
    tester,
  ) async {
    final journal = _Journal();
    final container = ProviderContainer(
      overrides: [
        assistantChangeJournalProvider.overrideWithValue(journal),
        assistantRunStartProvider(
          'assistant',
        ).overrideWithValue(DateTime(2026, 10, 17)),
        assistantRecentChangesProvider.overrideWith(
          (ref) async => journal.undone.isEmpty ? [_second, _entry] : const [],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(
            body: AssistantActivityPanel(conversationId: 'assistant'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本轮改动 2 项'), findsOneWidget);
    expect(find.text('· 改了「小理」的人设提示词'), findsOneWidget);

    final answer = container
        .read(assistantApprovalsProvider.notifier)
        .ask(
          const ApprovalPrompt(title: '更改角色「小理」的插件', detail: '开启：联网搜索'),
          Completer<void>().future,
        );
    await tester.pump();
    expect(find.text('更改角色「小理」的插件'), findsOneWidget);
    await tester.tap(find.text('允许'));
    expect(await answer, isTrue);
    await tester.pump();
    expect(find.text('更改角色「小理」的插件'), findsNothing);

    await tester.tap(find.text('全部撤销'));
    await tester.pumpAndSettle();
    expect(journal.undone, ['chg_2', 'chg_1']);
    expect(find.textContaining('本轮改动'), findsNothing);
    // Let the「已撤销」toast run out.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a withdrawn request removes its card and counts as no', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        assistantRecentChangesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(
            body: AssistantActivityPanel(conversationId: 'assistant'),
          ),
        ),
      ),
    );
    final withdrawn = Completer<void>();
    final answer = container
        .read(assistantApprovalsProvider.notifier)
        .ask(
          const ApprovalPrompt(title: '新建角色「小新」', detail: ''),
          withdrawn.future,
        );
    await tester.pump();
    expect(find.text('新建角色「小新」'), findsOneWidget);
    withdrawn.complete();
    expect(await answer, isFalse);
    await tester.pump();
    expect(find.text('新建角色「小新」'), findsNothing);
  });

  testWidgets('a key typed into the card goes to the channel only', (
    tester,
  ) async {
    final settings = FakeSettings(
      settingsWith([deepSeek(enabled: false)], 'deepseek:deepseek-flash'),
    );
    final container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWith(() => settings),
        assistantRecentChangesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(
            body: AssistantActivityPanel(conversationId: 'assistant'),
          ),
        ),
      ),
    );
    container
        .read(assistantCardsProvider.notifier)
        .requestKey('deepseek', 'DeepSeek');
    await tester.pump();
    expect(find.text('填写「DeepSeek」的 API Key'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('assistant-key-request-field')),
      '  sk-typed  ',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.savedKeys, [
      ['sk-typed'],
    ]);
    expect(settings.enabledProviders, ['deepseek']);
    expect(container.read(assistantCardsProvider), isEmpty);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
