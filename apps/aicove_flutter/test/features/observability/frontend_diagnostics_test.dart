import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/frontend_error_capture.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_port.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('诊断异步通知、关联本轮；首段布局每操作只记录一次', () async {
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    final requested =
        diagnostics.begin(FrontendStage.sendRequested, conversationId: 'conv');
    final linked = diagnostics.linkTurn(
        conversationId: 'conv', turnId: 'turn', traceId: 'trace');
    expect(logs, isEmpty);
    expect(linked.operationId, requested.operationId);
    diagnostics.bindMessage('m1', linked);
    diagnostics.bindMessage('m2', linked);
    for (var i = 0; i < 100; i++) {
      diagnostics.record(linked, FrontendStage.firstTextLayout, once: true);
    }
    await Future<void>.delayed(Duration.zero);
    expect(logs, hasLength(3));
    expect(diagnostics.forMessage('m1')?.traceId, 'trace');
    expect(logs.last.traceId, 'trace');
    expect(logs.last.metadata?['elapsedMs'], isNonNegative);
  });

  test('重试旧消息也创建独立操作，已绑定气泡不串到新一轮', () async {
    final diagnostics = FrontendDiagnosticsService(sink: (_) {});
    final first = diagnostics.linkTurn(
        conversationId: 'conv', turnId: 'same-message', traceId: 'trace1');
    diagnostics.bindMessage('old-bubble', first);
    final second = diagnostics.linkTurn(
        conversationId: 'conv', turnId: 'same-message', traceId: 'trace2');
    expect(second.operationId, isNot(first.operationId));
    expect(diagnostics.forMessage('old-bubble')?.traceId, 'trace1');
    expect(diagnostics.forTurn('same-message')?.traceId, 'trace2');
    await Future<void>.delayed(Duration.zero);
  });

  test('只记录异常类型和代码位置，不保存错误正文、密钥和本机路径', () async {
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    diagnostics.record(
      FrontendDiagnosticContext(operationId: 'error1'),
      FrontendStage.frameworkError,
      error: StateError(
          'private conversation Authorization: Bearer secret https://secret.example'),
      stackTrace: StackTrace.fromString(
          '#0 private (/Users/patient/private.dart:2:3)\n#1 f (package:aicove_flutter/page.dart:4:5)'),
    );
    await Future<void>.delayed(Duration.zero);
    final raw = jsonEncode(logs.single.toJson());
    expect(raw, isNot(contains('secret')));
    expect(raw, isNot(contains('private')));
    expect(raw, isNot(contains('/Users')));
    expect(raw, contains('StateError'));
    expect(raw, contains('package:aicove_flutter/page.dart:4:5'));
  });

  test('采集开关与队列上限生效，诊断故障不会抛给业务', () async {
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    diagnostics.enabled = false;
    diagnostics.begin(FrontendStage.pageOpened);
    await Future<void>.delayed(Duration.zero);
    expect(logs, isEmpty);
    diagnostics.enabled = true;
    final context = FrontendDiagnosticContext(operationId: 'op');
    for (var i = 0; i < 150; i++) {
      diagnostics.record(context, FrontendStage.scrollDetached);
    }
    await Future<void>.delayed(Duration.zero);
    expect(logs, hasLength(129));
    expect(logs.last.metadata?['droppedCount'], 22);
    final broken =
        FrontendDiagnosticsService(sink: (_) => throw StateError('disk'));
    broken.begin(FrontendStage.pageOpened);
    await Future<void>.delayed(Duration.zero);
  });

  test('气泡关联表有界', () async {
    final diagnostics = FrontendDiagnosticsService(sink: (_) {});
    final context = FrontendDiagnosticContext(operationId: 'op');
    for (var i = 0; i < 600; i++) {
      diagnostics.bindMessage('m$i', context);
    }
    expect(diagnostics.forMessage('m0'), isNull);
    expect(diagnostics.forMessage('m599'), context);
  });

  test('全局异常采集保留已有处理器，不把未处理异常标成已处理', () async {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    var forwarded = 0;
    FlutterError.onError = (_) {
      forwarded++;
    };
    PlatformDispatcher.instance.onError = (_, __) {
      forwarded++;
      return false;
    };
    final logs = <LogEntry>[];
    final capture =
        FrontendErrorCapture(FrontendDiagnosticsService(sink: logs.add));
    addTearDown(() {
      capture.uninstall();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    });
    capture.install();
    capture.install();
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('hidden')));
    expect(
        PlatformDispatcher.instance.onError!(
            StateError('hidden'), StackTrace.current),
        isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(forwarded, 2);
    expect(logs, hasLength(2));
  });
}
