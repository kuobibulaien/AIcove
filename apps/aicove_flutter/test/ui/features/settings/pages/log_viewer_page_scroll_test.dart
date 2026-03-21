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

  testWidgets('LogViewerPage should show latest logs on first open',
      (tester) async {
    final baseTime = DateTime(2026, 3, 19, 20, 0, 0);
    AppLogger.entries.value = List<LogEntry>.generate(80, (index) {
      return LogEntry(
        time: baseTime.add(Duration(seconds: index)),
        level: LogLevel.info,
        source: '测试',
        message: '日志 $index',
      );
    });

    await tester.pumpWidget(_wrap(const LogViewerPage()));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(find.textContaining('日志 79'), findsOneWidget);

    final listView = tester
        .widgetList<ListView>(find.byType(ListView))
        .firstWhere((widget) => widget.controller != null);
    final controller = listView.controller!;

    expect(controller.hasClients, isTrue);
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(
        controller.offset, closeTo(controller.position.maxScrollExtent, 1.0));
  });
}
