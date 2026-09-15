import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/backup/backup_providers.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_importer.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_preview_page.dart';

class PendingImporter extends Fake implements ConversationImporter {
  void Function(ImportProgress)? progress;
  int calls = 0;
  final result = Completer<ImportResult>();
  @override
  Future<ImportResult> import(
      {required File file,
      required List<String> selectedScopes,
      required List<String> selectedConversationIds,
      Map<String, ImportConflictResolution> conflictResolutions = const {},
      void Function(ImportProgress)? onProgress}) {
    calls++;
    progress = onProgress;
    return result.future;
  }
}

ImportPreview preview(
        {List<String> scopes = const [SyncScope.characterCards],
        bool compatible = true}) =>
    ImportPreview(
        formatVersion: compatible ? 1 : 999,
        appVersion: 'audit',
        exportTime: DateTime(2026, 9, 6),
        includedScopes: scopes,
        isCompatible: compatible,
        conversations: const [
          ConversationPreview(id: 'a', displayName: '角色', messageCount: 1)
        ]);

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('U01 memory-only preview selects available scopes width=$width',
        (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
              home: ImportPreviewPage(
                  file: File('/synthetic-not-opened.aicove'),
                  preview: preview(scopes: [SyncScope.memory])))));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
          tester.element(find.byType(ImportPreviewPage)));
      expect(container.read(importScopesProvider), {SyncScope.memory});
    });
  }
  testWidgets('U02 incompatible preview must not invoke import',
      (tester) async {
    final importer = PendingImporter();
    await tester.pumpWidget(ProviderScope(
        overrides: [conversationImporterProvider.overrideWithValue(importer)],
        child: MaterialApp(
            home: ImportPreviewPage(
                file: File('/synthetic-not-opened.aicove'),
                preview: preview(compatible: false)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 1 个角色'));
    await tester.pump();
    final calls = importer.calls;
    await tester.pumpWidget(const SizedBox());
    importer.result.complete(const ImportResult(
        conversationIds: [], messagesImported: 0, filesImported: 0));
    await tester.pump();
    expect(calls, 0);
  });
  testWidgets('U03 import progress after disposal must be safe',
      (tester) async {
    final importer = PendingImporter();
    await tester.pumpWidget(ProviderScope(
        overrides: [conversationImporterProvider.overrideWithValue(importer)],
        child: MaterialApp(
            home: ImportPreviewPage(
                file: File('/synthetic-not-opened.aicove'),
                preview: preview()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 1 个角色'));
    await tester.pump();
    expect(importer.progress, isNotNull);
    await tester.pumpWidget(const SizedBox());
    Object? error;
    try {
      importer.progress!(const ImportProgress(ImportPhase.importing, 0.5));
    } catch (e) {
      error = e;
    }
    importer.result.complete(const ImportResult(
        conversationIds: [], messagesImported: 0, filesImported: 0));
    await tester.pump();
    expect(error, isNull);
  });
  testWidgets('U04 old file conflict choices must not carry into a new preview',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(importConflictResolutionsProvider.notifier)
        .setResolution('a', ImportConflictResolution.skip);
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: ImportPreviewPage(
                file: File('/new-synthetic.aicove'), preview: preview()))));
    await tester.pumpAndSettle();
    expect(container.read(importConflictResolutionsProvider), isEmpty);
  });
}
