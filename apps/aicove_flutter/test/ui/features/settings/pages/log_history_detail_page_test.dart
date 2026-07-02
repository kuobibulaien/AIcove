import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/log_history_service.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_history_detail_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens with latest log entry at the top', (tester) async {
    final baseTime = DateTime(2026, 3, 31, 10, 0, 0);
    final appLogs = <Map<String, dynamic>>[
      for (var i = 0; i < 80; i++)
        {
          'time': baseTime.add(Duration(seconds: i)).toIso8601String(),
          'level': 'INFO',
          'source': 'Test',
          'message': '日志 $i ${'x' * 80}',
        },
    ];

    final file = LogHistoryFile(
      fileName: 'app_2026-03-31.jsonl',
      createdAt: DateTime(2026, 3, 31),
      size: 1024,
      filePath: '/tmp/app_2026-03-31.jsonl',
      type: 'app',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LogHistoryDetailPage(
          file: file,
          loadHistoryFile: (_) async {
            return {
              'savedAt': baseTime.toIso8601String(),
              'apiLogs': <Map<String, dynamic>>[],
              'appLogs': appLogs,
            };
          },
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('日志 79'), findsOneWidget);
    expect(find.textContaining('日志 0'), findsNothing);

    final listView = tester.widget<ListView>(find.byType(ListView));
    final controller = listView.controller;
    expect(controller, isNotNull);
    expect(controller!.hasClients, isTrue);
    expect(controller.offset, closeTo(0, 1.0));
  });
}
