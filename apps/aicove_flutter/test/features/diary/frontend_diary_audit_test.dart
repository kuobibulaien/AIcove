import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/diary_repository.dart';
import 'package:aicove_flutter/src/features/diary/models/diary_entry.dart';
import 'package:aicove_flutter/src/features/diary/presentation/diary_list_page.dart';

class DeferredDiaryRepository extends Fake implements DiaryRepository {
  final result = Completer<List<DiaryEntry>>();
  @override
  Future<List<DiaryEntry>> getDiariesByConversation(String conversationId,
          {int? limit}) =>
      result.future;
}

Widget app(DeferredDiaryRepository repo) => ProviderScope(
      overrides: [diaryRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
          home: DiaryListPage(
              conversationId: 'synthetic', characterName: 'Synthetic')),
    );

void main() {
  testWidgets('diary read failure must not look like no diaries',
      (tester) async {
    final repo = DeferredDiaryRepository();
    await tester.pumpWidget(app(repo));
    repo.result.completeError(StateError('synthetic read failure'));
    await tester.pumpAndSettle();
    expect(find.text('还没有日记'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late diary result after leaving page is ignored',
      (tester) async {
    final repo = DeferredDiaryRepository();
    await tester.pumpWidget(app(repo));
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    repo.result.complete([]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
