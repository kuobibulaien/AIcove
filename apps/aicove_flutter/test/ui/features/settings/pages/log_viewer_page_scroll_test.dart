import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        MoeColors.light(),
      ],
    ),
    home: child,
  );
}

String _longChunk(String label) {
  return List<String>.filled(6, '$label ${'x' * 80}').join('\n');
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

ScrollController _findLogListController(WidgetTester tester) {
  final listView = tester
      .widgetList<ListView>(find.byType(ListView))
      .firstWhere((widget) => widget.controller != null);
  return listView.controller!;
}

void _expectShowingLatestAtBottom(
  WidgetTester tester, {
  required String latestText,
  required String oldestText,
}) {
  expect(find.textContaining(latestText), findsOneWidget);
  expect(find.textContaining(oldestText), findsNothing);

  final controller = _findLogListController(tester);
  expect(controller.hasClients, isTrue);
  expect(controller.position.maxScrollExtent, greaterThan(0));
  expect(
    controller.offset,
    closeTo(controller.position.maxScrollExtent, 1.0),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('log_viewer_scroll_test');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    ApiLogger.clear();
    AppLogger.clear();
    TraceStore.instance.debugResetForTest();
  });

  tearDown(() async {
    ApiLogger.clear();
    AppLogger.clear();
    TraceStore.instance.debugResetForTest();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets(
      'LogViewerPage keeps latest log visible for all/API/system filters',
      (tester) async {
    final baseTime = DateTime(2026, 3, 19, 20, 0, 0);
    AppLogger.entries.value = List<LogEntry>.generate(40, (index) {
      return LogEntry(
        time: baseTime.add(Duration(seconds: 100 + index)),
        level: LogLevel.info,
        source: '测试',
        message: '系统日志 $index ${_longChunk('system-$index')}',
      );
    });
    ApiLogger.entries.value = List<ApiLogEntry>.generate(40, (index) {
      return ApiLogEntry(
        time: baseTime.add(Duration(seconds: index)),
        method: 'GET',
        url: 'https://example.com/logs/$index',
        status: 200,
        durationMs: 120 + index,
        requestBody: _longChunk('api-request-$index'),
        responseBody: _longChunk('api-response-$index'),
        ok: true,
      );
    });

    await tester.pumpWidget(_wrap(const LogViewerPage()));
    await _pumpFrames(tester);

    _expectShowingLatestAtBottom(
      tester,
      latestText: '系统日志 39',
      oldestText: 'https://example.com/logs/0',
    );

    await tester.tap(find.text('API'));
    await _pumpFrames(tester);
    _expectShowingLatestAtBottom(
      tester,
      latestText: '/logs/39',
      oldestText: '/logs/0',
    );

    await tester.tap(find.text('系统'));
    await _pumpFrames(tester);
    _expectShowingLatestAtBottom(
      tester,
      latestText: '系统日志 39',
      oldestText: '系统日志 0',
    );
  });
}
