import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/backup/backup_providers.dart';
import 'package:aicove_flutter/src/features/backup/data/conversation_exporter.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/export_scope_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/export_character_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/chat_preview_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_preview_page.dart';

import '../../../helpers/release_source_preview.dart';

Conversation conversation(int i) => Conversation(
    id: 'audit-$i',
    title: 'Audit $i',
    displayName: 'Audit $i',
    createdAt: DateTime(2026, 9, 6),
    updatedAt: DateTime(2026, 9, 6));

class AuditConversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => List.generate(100, conversation);
}

class AuditHistory extends Fake implements ChatHistoryStore {
  @override
  Future<int> loadMessageCount(String conversationId) async => 100;
  @override
  Future<List<Message>> loadProjectedMessagesFromRawStore(
          String conversationId) async =>
      [];
}

class DeferredExporter extends Fake implements ConversationExporter {
  final result = Completer<ExportResult>();
  void Function(ExportProgress)? progress;
  @override
  Future<ExportResult> exportConversations(
      {required List<String> conversationIds,
      ExportOptions options = const ExportOptions(),
      void Function(ExportProgress)? onProgress}) {
    progress = onProgress;
    return result.future;
  }
}

void main() {
  for (final size in [const Size(320, 568), const Size(1000, 768)]) {
    for (final scale in [1.2, 1.8]) {
      for (final page in ['scope', 'export', 'preview', 'import']) {
        testWidgets('backup $page size=$size scale=$scale', (tester) async {
          await loadReleasePreviewFonts(tester);
          final previewKey = GlobalKey();
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final Widget home = switch (page) {
            'scope' => const ExportScopePage(),
            'export' => const ExportCharacterPage(),
            'preview' => ChatPreviewPage(conversation: conversation(0)),
            _ => ImportPreviewPage(
                file: File('/synthetic-not-opened.zip'),
                preview: ImportPreview(
                    formatVersion: 1,
                    appVersion: 'audit',
                    exportTime: DateTime(2026, 9, 6),
                    includedScopes: [SyncScope.characterCards],
                    conversations: List.generate(
                        100,
                        (i) => ConversationPreview(
                            id: 'audit-$i',
                            displayName: 'Audit $i',
                            messageCount: 100)))),
          };
          await tester.pumpWidget(ProviderScope(
              overrides: [
                conversationsProvider.overrideWith(AuditConversations.new),
                chatHistoryStoreProvider.overrideWithValue(AuditHistory()),
              ],
              child: RepaintBoundary(
                key: previewKey,
                child: MaterialApp(
                  theme: captureReleaseSourcePreview
                      ? ThemeData(fontFamily: 'ReleasePreview')
                      : null,
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!),
                  home: home))));
          await tester.pumpAndSettle();
          if (page == 'export') {
            final container = ProviderScope.containerOf(
                tester.element(find.byType(ExportCharacterPage)));
            container
                .read(selectedConversationsProvider.notifier)
                .selectAll(List.generate(100, (i) => 'audit-$i'));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await saveReleaseSourcePreview(tester, previewKey,
              'backup-$page-${size.width.toInt()}-$scale');
          if (page == 'export' || page == 'import') {
            await tester.scrollUntilVisible(find.text('Audit 99'), 350,
                scrollable: find.byType(Scrollable).first, maxScrolls: 100);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('Audit 99').hitTestable(), findsOneWidget);
          }
        });
      }
    }
  }
  testWidgets('export progress remains safe after page disposal',
      (tester) async {
    final exporter = DeferredExporter();
    await tester.pumpWidget(ProviderScope(overrides: [
      conversationsProvider.overrideWith(AuditConversations.new),
      chatHistoryStoreProvider.overrideWithValue(AuditHistory()),
      conversationExporterProvider.overrideWithValue(exporter),
    ], child: const MaterialApp(home: ExportCharacterPage())));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
        tester.element(find.byType(ExportCharacterPage)));
    container
        .read(selectedConversationsProvider.notifier)
        .selectAll(['audit-0']);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 1 个角色'));
    await tester.pump();
    expect(exporter.progress, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    Object? error;
    try {
      exporter.progress!(const ExportProgress(ExportPhase.queryingData, 0.5));
    } catch (e) {
      error = e;
    }
    exporter.result.complete(const ExportResult(
        filePath: '/synthetic-not-created.zip',
        fileName: 'audit.zip',
        conversationCount: 1,
        messageCount: 0,
        fileCount: 0,
        sizeBytes: 0));
    await tester.pump();
    expect(error, isNull,
        reason:
            'a late service progress callback must not access a disposed widget ref');
  });
}
