import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/agent_plugins/file_change_journal.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_approvals.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_cards.dart';
import 'package:aicove_flutter/src/features/assistant/application/assistant_review.dart';
import 'package:aicove_flutter/src/features/assistant/assistant_providers.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/assistant/widgets/assistant_activity_panel.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../features/assistant/assistant_onboarding_test.dart'
    show FakeSettings, deepSeek, settingsWith;

final _entry = JournalEntry(
  id: 'chg_1',
  toolName: 'aicove_update_role',
  change: const ReversibleChange(
    kind: 'assistant.role',
    description: '改了「小理」的人设提示词',
    before: {},
    after: {},
  ),
  createdAt: DateTime(2026, 10, 17),
);

class _Journal extends FileChangeJournal {
  _Journal() : super(file: () async => File('unused'), appliers: const {});

  final undone = <String>[];

  @override
  Future<JournalEntry> undo(String entryId) async {
    undone.add(entryId);
    return _entry;
  }
}

void main() {
  testWidgets('approval cards answer the run; changes can be undone', (
    tester,
  ) async {
    final journal = _Journal();
    final container = ProviderContainer(
      overrides: [
        assistantChangeJournalProvider.overrideWithValue(journal),
        assistantRecentChangesProvider.overrideWith(
          (ref) async => journal.undone.isEmpty ? [_entry] : const [],
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: const Scaffold(body: AssistantActivityPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('改了「小理」的人设提示词'), findsOneWidget);

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

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(journal.undone, ['chg_1']);
    expect(find.text('改了「小理」的人设提示词'), findsNothing);
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
          home: const Scaffold(body: AssistantActivityPanel()),
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
          home: const Scaffold(body: AssistantActivityPanel()),
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
