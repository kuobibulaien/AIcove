import 'dart:io';

import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/export_scope_page.dart';
import 'package:aicove_flutter/src/ui/features/backup/pages/import_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/release_source_preview.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final page in ['export', 'unsupported-import']) {
      testWidgets('transfer coverage $page width=$width', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await loadReleasePreviewFonts(tester);
        final key = GlobalKey();
        await tester.pumpWidget(ProviderScope(
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: ThemeData(fontFamily: 'ReleasePreview'),
              home: page == 'export'
                  ? const ExportScopePage()
                  : ImportPreviewPage(
                      file: File('/synthetic-unopened.aicove'),
                      preview: ImportPreview(
                        formatVersion: 1,
                        appVersion: 'audit',
                        exportTime: DateTime(2026, 10, 2),
                        includedScopes: const [SyncScope.memory],
                        conversations: const [
                          ConversationPreview(
                            id: 'a',
                            displayName: '示例角色',
                            messageCount: 2,
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.text(transferCoverageNotice), findsOneWidget);
        if (page == 'unsupported-import') {
          expect(find.text('此文件没有当前支持的恢复内容'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await saveReleaseSourcePreview(
          tester,
          key,
          'transfer-$page-${width.toInt()}',
        );
      });
    }
  }
}
