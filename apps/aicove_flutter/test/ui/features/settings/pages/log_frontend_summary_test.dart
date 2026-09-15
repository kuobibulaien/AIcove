import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_viewer/log_viewer_unified_list.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_formatters.dart';
import 'package:aicove_flutter/src/ui/features/settings/pages/log_models.dart';

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final scale in [1.2, 1.8]) {
      testWidgets('日志统计窄宽屏可读 width=$width scale=$scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = ScrollController();
        final entries = buildUnifiedEntries([], [
          LogEntry(
            time: DateTime(2026),
            level: LogLevel.warning,
            source: 'FrontendDiagnostics',
            message: '历史窗口冷加载',
            metadata: {
              'category': 'frontend',
              'event': 'historyColdLoad',
              'phase': 'end',
              'elapsedMs': 1065,
              'state': {
                'rawReadMs': 900,
                'rawPayloadChars': 39284777,
                'payloadToolResultChars': 39000000,
                'payloadScanTruncated': false,
              }
            },
          )
        ]);
        await tester.pumpWidget(MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: Scaffold(
                body: LogViewerUnifiedList(
              entries: entries,
              scrollController: controller,
              expandedIndices: const {0},
              selectedIndices: const {},
              isSelectionMode: false,
              onToggleSelection: (_) {},
              onToggleExpansion: (_) {},
              onEnterSelectionMode: (_) {},
            ))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('历史加载完成'), findsOneWidget);
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    }
  }

  test('旧音频累计时间不冒充动画耗时', () {
    final entries = buildUnifiedEntries([], [
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.info,
        source: 'FrontendDiagnostics',
        message: '气泡入场动画裁决',
        metadata: {
          'category': 'frontend',
          'event': 'animationDecision',
          'operationId': 'audio_old',
          'elapsedMs': 2670,
          'state': {'animate': false}
        },
      )
    ]);
    expect(entries.single.title, '跳过入场动画');
    expect(entries.single.fullContent, contains('2670'));
  });

  test('冷加载直观展示阶段耗时与大字段统计', () {
    final entries = buildUnifiedEntries([], [
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.info,
        source: 'FrontendDiagnostics',
        message: '历史窗口冷加载',
        metadata: {
          'category': 'frontend',
          'event': 'historyColdLoad',
          'phase': 'end',
          'elapsedMs': 1065,
          'state': {
            'rawReadMs': 900,
            'decodeMs': 89,
            'projectionMs': 74,
            'rawCount': 20,
            'rawPayloadChars': 39284777,
            'payloadToolResultChars': 39000000,
            'payloadScanTruncated': true,
          }
        },
      )
    ]);
    expect(entries.single.title, contains('用时 1065ms'));
    expect(entries.single.fullContent, contains('原始工具结果'));
    expect(entries.single.fullContent, contains('仅统计字符串值'));
    expect(entries.single.fullContent, contains('统计已截断'));
  });

  test('只看异常也过滤成功的网络请求', () {
    final entries = buildUnifiedEntries([
      for (final ok in [true, false])
        ApiLogEntry(
            time: DateTime(2026),
            method: 'POST',
            url: '/chat',
            status: ok ? 200 : 500,
            durationMs: 20,
            requestBody: '',
            responseBody: '',
            ok: ok),
    ], [], levelFilter: LogLevelFilter.error);
    expect(entries, hasLength(1));
    expect(entries.single.level, LogLevel.error);
  });

  test('前端摘要不用技术前缀，详情保留关联编号', () {
    final entries = buildUnifiedEntries([], [
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.info,
        source: 'FrontendDiagnostics',
        message: '聊天列表完成布局',
        metadata: {
          'category': 'frontend',
          'event': 'pageLayoutReady',
          'operationId': 'op_1',
          'elapsedMs': 120,
        },
      )
    ]);
    expect(entries.single.title, '聊天列表完成布局 · 进入后 120ms');
    expect(entries.single.fullContent, contains('op_1'));
  });
}
