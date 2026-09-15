import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_port.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/frontend_message_probe.dart';

void main() {
  testWidgets('只在首段真实文字完成布局后记录，多次增量不会刷日志', (tester) async {
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    diagnostics.bindMessage('m', FrontendDiagnosticContext(operationId: 'op'));
    Widget build(bool ready) => ProviderScope(
          overrides: [
            frontendDiagnosticsProvider.overrideWithValue(diagnostics)
          ],
          child: MaterialApp(
              home: Scaffold(
                  body: FrontendMessageProbe(
            messageId: 'm',
            hasText: ready,
            child: Text(ready ? '回复' : '生成中'),
          ))),
        );
    await tester.pumpWidget(build(false));
    expect(logs, isEmpty);
    await tester.pumpWidget(build(true));
    await tester.pump();
    expect(logs, hasLength(1));
    expect(logs.single.metadata?['event'], 'firstTextLayout');
    await tester.pumpWidget(build(true));
    await tester.pump();
    expect(logs, hasLength(1));
  });

  testWidgets('视口外预布局不能冒充用户看到首段回复', (tester) async {
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    diagnostics.bindMessage('m', FrontendDiagnosticContext(operationId: 'op'));
    await tester.pumpWidget(ProviderScope(
      overrides: [frontendDiagnosticsProvider.overrideWithValue(diagnostics)],
      child: const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
        child: Column(children: [
          SizedBox(height: 1400),
          FrontendMessageProbe(
            messageId: 'm',
            hasText: true,
            child: Text('还在屏幕外'),
          )
        ]),
      ))),
    ));
    await tester.pump();
    expect(logs, isEmpty);
  });
}
