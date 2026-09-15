import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_access_port.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/ui/features/debug/pages/diagnostic_access_page.dart';

class FakeAccess implements DiagnosticAccessPort {
  @override
  final ValueNotifier<DiagnosticAccessSession?> session =
      ValueNotifier<DiagnosticAccessSession?>(null);
  @override
  Future<void> start() async =>
      session.value = DiagnosticAccessSession(48631, 'a' * 43);
  @override
  Future<void> stop() async => session.value = null;
  @override
  Future<Uint8List> exportBundle() async => Uint8List(0);
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('诊断入口 ${width}px 下自动开启、显示命令且没有关闭开关', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final access = FakeAccess();
      await access.start();
      await tester.pumpWidget(ProviderScope(overrides: [
        diagnosticAccessProvider.overrideWithValue(access),
      ], child: const MaterialApp(home: DiagnosticAccessPage())));
      expect(find.text('保存诊断包'), findsOneWidget);
      expect(find.text('已自动开启，持续有效；应用重启后自动恢复'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(
          find.textContaining('--release', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
      await access.stop();
      await tester.pumpAndSettle();
      expect(find.text('复制电脑采集命令'), findsNothing);
      expect(find.text('正在自动连接，暂不可用时会重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
