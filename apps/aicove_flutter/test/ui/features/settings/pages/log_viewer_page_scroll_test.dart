import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_port.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer_page.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer/log_viewer_trace_conversation_view.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

class _FakeTraceExporter implements TraceExportPort {
  String? requestedTrace;
  @override
  Future<String?> exportTurn(String traceId) async {
    requestedTrace = traceId;
    return null;
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

Widget _wrap(Widget child, {TraceExportPort? exporter}) {
  return ProviderScope(
      overrides: [
        if (exporter != null) traceExportProvider.overrideWithValue(exporter)
      ],
      child: MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[
            MoeColors.light(),
          ],
        ),
        home: child,
      ));
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

  testWidgets('log overflow preserves capture check state and delayed selection', (tester) async {
    await tester.pumpWidget(_wrap(const LogViewerPage()));
    await _pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LogViewerPage)));
    final diagnostics = container.read(frontendDiagnosticsProvider);
    final before = diagnostics.enabled;
    addTearDown(() => diagnostics.enabled = before);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    final label = find.text('记录前端响应（本次运行）');
    expect(label, findsOneWidget);
    expect(find.byIcon(Icons.check), before ? findsOneWidget : findsNothing);
    await tester.tap(label);
    await tester.pump();
    expect(diagnostics.enabled, before);
    await tester.pumpAndSettle();
    expect(diagnostics.enabled, !before);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), before ? findsNothing : findsOneWidget);
    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(label, findsNothing);
    expect(tester.takeException(), isNull);
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

    await tester.tap(find.text('网络'));
    await _pumpFrames(tester);
    _expectShowingLatestAtBottom(
      tester,
      latestText: '/logs/39',
      oldestText: '/logs/0',
    );

    await tester.tap(find.text('应用').first);
    await _pumpFrames(tester);
    _expectShowingLatestAtBottom(
      tester,
      latestText: '系统日志 39',
      oldestText: '系统日志 0',
    );
  });

  testWidgets('对话导出按钮调用单轮导出端口，不再导出当前内存API列表', (tester) async {
    final trace = await tester.runAsync(() async {
      final result = await TraceStore.instance
          .startTurn(sessionId: 'conv', turnId: 'turn');
      await TraceStore.instance.waitForPendingWrites();
      expect(await TraceStore.instance.readRecentEvents(), hasLength(1));
      return result;
    });
    final exporter = _FakeTraceExporter();
    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const LogViewerPage(), exporter: exporter));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.tap(find.text('对话'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await _pumpFrames(tester);
    final view = tester.widget<LogViewerTraceConversationView>(
        find.byType(LogViewerTraceConversationView));
    expect(view.traceLoading, isFalse, reason: '历史读取应完成');
    expect(view.turns, hasLength(1));
    expect(view.selectedTurn, isNotNull);
    await tester.tap(find.byTooltip('导出选中对话（含前端记录）'));
    await _pumpFrames(tester);
    expect(exporter.requestedTrace, trace!.traceId);
    await tester.pump(const Duration(seconds: 4));
  });

  for (final width in [320.0, 390.0, 1200.0]) {
    testWidgets('日志中心 $width 宽度：中文筛选、摘要与折叠详情', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 840));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      AppLogger.entries.value = [
        LogEntry(
          time: DateTime(2026),
          level: LogLevel.info,
          source: 'FrontendDiagnostics',
          message: '聊天列表完成布局',
          metadata: {
            'category': 'frontend',
            'operationId': 'test_operation_123',
            'elapsedMs': 120,
          },
        )
      ];
      await tester.pumpWidget(_wrap(const LogViewerPage()));
      await _pumpFrames(tester);
      expect(tester.getRect(find.text('只看异常')).right, lessThanOrEqualTo(width));
      await tester.tap(find.text('前端').first);
      await _pumpFrames(tester);
      expect(find.text('聊天列表完成布局 · 120ms'), findsOneWidget);
      expect(find.textContaining('test_operation_123'), findsNothing);
      await tester.tap(find.text('聊天列表完成布局 · 120ms'));
      await tester.pump();
      expect(find.textContaining('test_operation_123'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
