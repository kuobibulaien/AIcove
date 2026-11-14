import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/features/observability/model_request_ledger.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer_page.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_PREVIEW');

  setUpAll(() async {
    if (!capture) return;
    final fontBytes = await File(
      '/System/Library/Fonts/STHeiti Medium.ttc',
    ).readAsBytes();
    final cjk = FontLoader('PreviewCJK')
      ..addFont(Future.value(ByteData.sublistView(fontBytes)));
    await cjk.load();
    final mono = FontLoader('monospace')
      ..addFont(Future.value(ByteData.sublistView(fontBytes)));
    await mono.load();
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });

  testWidgets('displays synced remote model runs with plain Chinese copy', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(780, 1440);

    SharedPreferences.setMockInitialValues({
      'aicove.cloud.device_id': 'device-mac-local',
    });

    final baseMs = DateTime(2026, 11, 13, 2, 30, 0).millisecondsSinceEpoch;
    final sampleRuns = <ModelRunRecord>[
      ModelRunRecord(
        runId: 'run-local-ignored',
        deviceId: 'device-mac-local',
        deviceName: '我的电脑',
        conversationId: 'conv-1',
        purpose: 'chat',
        providerId: 'openai',
        model: 'gpt-4o',
        attempt: 1,
        status: 'succeeded',
        stageSeq: 1000,
        startedAtMs: baseMs,
        updatedAtMs: baseMs + 500,
        endedAtMs: baseMs + 500,
        durationMs: 500,
        leaseUntilMs: baseMs + 180000,
      ),
      ModelRunRecord(
        runId: 'run-phone-memory',
        deviceId: 'device-phone-remote',
        deviceName: '我的手机',
        conversationId: 'conv-1',
        purpose: 'memory_consolidate',
        providerId: 'deepseek',
        model: 'deepseek-chat',
        attempt: 1,
        status: 'succeeded',
        stageSeq: 1000,
        startedAtMs: baseMs + 10000,
        updatedAtMs: baseMs + 11840,
        endedAtMs: baseMs + 11840,
        durationMs: 1840,
        leaseUntilMs: baseMs + 190000,
      ),
      ModelRunRecord(
        runId: 'run-phone-failed',
        deviceId: 'device-phone-remote',
        deviceName: '我的手机',
        conversationId: 'conv-1',
        purpose: 'chat',
        providerId: 'deepseek',
        model: 'deepseek-chat',
        attempt: 2,
        status: 'failed',
        stageSeq: 1000,
        startedAtMs: baseMs + 25000,
        updatedAtMs: baseMs + 25620,
        endedAtMs: baseMs + 25620,
        durationMs: 620,
        leaseUntilMs: baseMs + 205000,
        errorBrief: '请求超时',
      ),
      ModelRunRecord(
        runId: 'run-phone-running',
        deviceId: 'device-phone-remote',
        deviceName: '我的手机',
        conversationId: 'conv-1',
        purpose: 'chat',
        providerId: 'deepseek',
        model: 'deepseek-chat',
        attempt: 1,
        status: 'running',
        stageSeq: 2,
        startedAtMs: baseMs + 42000,
        updatedAtMs: baseMs + 42000,
        leaseUntilMs: baseMs + 222000,
      ),
    ];

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelRunsProvider.overrideWith((ref) => Stream.value(sampleRuns)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFC96AA),
              primary: const Color(0xFFFC96AA),
              brightness: Brightness.light,
              surface: moeSurface,
              onSurface: moeText,
            ),
            scaffoldBackgroundColor: moeSurface,
            fontFamily: capture ? 'PreviewCJK' : null,
            extensions: [MoeColors.light()],
          ),
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: const LogViewerPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('来自 我的手机 · 长期记忆整理已完成 · 1840ms'), findsOneWidget);
    expect(find.text('来自 我的手机 · 对话回复失败 · 620ms'), findsOneWidget);
    expect(find.text('来自 我的手机 · 对话回复生成中'), findsOneWidget);
    expect(find.textContaining('我的电脑'), findsNothing);
    expect(find.textContaining('memory_consolidate'), findsNothing);
    expect(find.textContaining('succeeded'), findsNothing);

    await tester.tap(find.text('来自 我的手机 · 对话回复失败 · 620ms'));
    await tester.pumpAndSettle();

    expect(find.textContaining('原因：请求超时'), findsOneWidget);
    expect(find.textContaining('重试：第 2 次'), findsOneWidget);

    if (capture) {
      final outPath = Platform.environment['PREVIEW_OUT_PATH'] ??
          '../../scratch/log_viewer_remote_runs_preview.png';
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2.0);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
