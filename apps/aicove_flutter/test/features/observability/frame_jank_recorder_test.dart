import 'dart:ui';

import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_bundle.dart';
import 'package:aicove_flutter/src/features/observability/frame_jank_recorder.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';
import 'package:aicove_flutter/src/ui/shared/animations/parallax_slide_page_route.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FrameTiming _frame({int uiMs = 2, int rasterMs = 2, int waitMs = 0}) {
  const start = 1000000;
  final buildStart = start + waitMs * 1000;
  final buildFinish = buildStart + uiMs * 1000;
  final rasterFinish = buildFinish + rasterMs * 1000;
  return FrameTiming(
    vsyncStart: start,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: buildFinish,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: DateTime.now().microsecondsSinceEpoch,
  );
}

Map<String, dynamic> _meta(LogEntry entry) => entry.metadata!;
Map<dynamic, dynamic> _state(LogEntry entry) => _meta(entry)['state'] as Map;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LogEntry> logs;
  late FrameJankRecorder recorder;

  setUp(() {
    logs = [];
    recorder = FrameJankRecorder(FrontendDiagnosticsService(sink: logs.add))
      ..pageName = () => 'ChatPage';
  });

  Future<List<LogEntry>> drained() async {
    await Future<void>.delayed(Duration.zero);
    return logs;
  }

  testWidgets('心跳捕捉卡顿，静置停表，收到帧后恢复', (tester) async {
    final start = tester.binding.clock.now();
    var stall = Duration.zero;
    final active = FrameJankRecorder(
      FrontendDiagnosticsService(sink: logs.add),
      elapsed: () => tester.binding.clock.now().difference(start) + stall,
    );
    active.install();
    addTearDown(active.uninstall);
    active.didChangeAppLifecycleState(AppLifecycleState.resumed);
    active.handleTimings([_frame()]);

    stall = const Duration(milliseconds: 300);
    await tester.pump(const Duration(milliseconds: 100));
    expect(logs.map((entry) => _meta(entry)['event']), contains('uiStall'));
    expect(active.isBeatRunning, isTrue);

    await tester.pump(const Duration(seconds: 3));
    expect(active.isBeatRunning, isFalse);
    active.handleTimings([]);
    expect(active.isBeatRunning, isFalse);
    active.handleTimings([_frame()]);
    expect(active.isBeatRunning, isTrue);
    active.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(active.isBeatRunning, isFalse);
    final summary = logs.lastWhere(
      (entry) => _meta(entry)['event'] == 'frameSummary',
    );
    expect(_state(summary)['frames'], 2);
  });

  test('普通帧只累加不写日志，汇总分开界面和绘制耗时', () async {
    recorder.handleTimings([
      for (var i = 0; i < 99; i++) _frame(uiMs: 3, rasterMs: 5),
      _frame(uiMs: 40, rasterMs: 5),
    ]);
    expect(await drained(), isEmpty);

    recorder.flushWindow();
    final entry = (await drained()).single;
    final state = _state(entry);
    expect(_meta(entry)['event'], 'frameSummary');
    expect(_meta(entry)['pageName'], 'ChatPage');
    expect(state['frames'], 100);
    expect(state['slowFrames'], 0);
    expect(state['uiP50Ms'], closeTo(3, 0.5));
    expect(state['uiMaxMs'], 40);
    expect(state['rasterP95Ms'], closeTo(5, 0.5));
  });

  test('空窗口不写汇总，汇总后清零', () async {
    recorder.flushWindow();
    expect(await drained(), isEmpty);

    recorder.handleTimings([_frame()]);
    recorder.flushWindow();
    recorder.flushWindow();
    expect(await drained(), hasLength(1));
  });

  test('严重帧单独记录并区分卡在哪一段', () async {
    recorder.handleTimings([_frame(uiMs: 120, rasterMs: 10, waitMs: 5)]);
    final entry = (await drained()).single;
    final state = _state(entry);
    expect(_meta(entry)['event'], 'slowFrame');
    expect(state['uiMs'], 120);
    expect(state['rasterMs'], 10);
    expect(state['vsyncMs'], 5);
    expect(state['totalMs'], 135);
  });

  test('卡顿和慢帧只关联时间窗内的阶段与同步段', () async {
    final now = DateTime.now().microsecondsSinceEpoch;
    recorder.recordSyncSpan('lan.old', now - 2000000, now - 1980000);
    recorder.recordSyncSpan('lan.short', now - 5000, now);
    recorder.recordSyncSpan('lan.work', now - 30000, now - 10000);
    recorder.enterPhase('lan.capture');
    recorder.handleBeatLateness(const Duration(milliseconds: 300));
    recorder.handleTimings([_frame(uiMs: 120)]);
    recorder.exitPhase('lan.capture');
    final entries = await drained();
    for (final entry in entries) {
      final state = _state(entry);
      expect(state['activePhases'], ['lan.capture']);
      expect(state['syncSpans'], [
        {'tag': 'lan.work', 'ms': 20.0},
      ]);
    }
  });

  test('超过上限的样本不写日志，只在汇总里计数', () async {
    for (var i = 0; i < 25; i++) {
      recorder.handleBeatLateness(const Duration(milliseconds: 300));
    }
    expect(await drained(), hasLength(10));

    recorder.flushWindow();
    final state = _state((await drained()).last);
    expect(state['stalls'], 25);
    expect(state['stallTotalMs'], 7500);
    expect(state['suppressedSamples'], 15);
  });

  test('延迟太短或疑似进程被挂起时不算卡顿', () async {
    recorder.handleBeatLateness(const Duration(milliseconds: 149));
    recorder.handleBeatLateness(const Duration(seconds: 60));
    recorder.flushWindow();
    expect(await drained(), isEmpty);
  });

  test('一批帧跨过切页时不归到任何一个页面', () async {
    recorder.handleTimings([_frame()]);
    recorder.pageName = () => 'SettingsPage';
    recorder.handleTimings([_frame(uiMs: 150)]);
    recorder.handleTimings([_frame(uiMs: 150)]);
    recorder.flushWindow();
    final entries = await drained();
    expect(_meta(entries[0])['pageName'], FrameJankRecorder.mixedPage);
    expect(_meta(entries[1])['pageName'], 'SettingsPage');
    expect(_meta(entries[2])['pageName'], FrameJankRecorder.mixedPage);
  });

  test('取不到页面或页面名不合格式时不写入可疑内容', () async {
    recorder.pageName = () => null;
    recorder.handleBeatLateness(const Duration(milliseconds: 300));
    recorder.pageName = () => 'https://example.com/秘密';
    recorder.handleBeatLateness(const Duration(milliseconds: 300));
    final entries = await drained();
    expect(_meta(entries[0])['pageName'], FrameJankRecorder.unknownPage);
    expect(_meta(entries[1]).containsKey('pageName'), isFalse);
  });

  test('页面名和卡顿数据能通过诊断导出过滤', () async {
    recorder.handleBeatLateness(const Duration(milliseconds: 300));
    final entry = (await drained()).single;
    final safe = sanitizeDiagnosticEntry(entry.toJson(), 'app_logs_x.jsonl');
    final meta = safe!['metadata'] as Map;
    expect(meta['pageName'], 'ChatPage');
    expect((meta['state'] as Map)['stallMs'], 300);
  });

  test('离开前台后才回传的帧不计入，回到前台继续统计', () async {
    recorder.didChangeAppLifecycleState(AppLifecycleState.paused);
    recorder.handleTimings([_frame(uiMs: 150)]);
    recorder.flushWindow();
    expect(await drained(), isEmpty);

    recorder.didChangeAppLifecycleState(AppLifecycleState.resumed);
    recorder.handleTimings([_frame()]);
    recorder.uninstall();
    recorder.flushWindow();
    expect(_state((await drained()).single)['frames'], 1);
  });

  test('分位数封顶 200ms，不被单个极慢帧放大', () async {
    recorder.handleTimings([
      for (var i = 0; i < 19; i++) _frame(uiMs: 300),
      _frame(uiMs: 10000),
    ]);
    recorder.flushWindow();
    final state = _state((await drained()).last);
    expect(state['uiP95Ms'], 200);
    expect(state['uiMaxMs'], 10000);
  });

  test('下划线开头的页面类型名能写入', () async {
    recorder.pageName = () => '_InlineImagePromptPage';
    recorder.handleBeatLateness(const Duration(milliseconds: 300));
    expect(
      _meta((await drained()).single)['pageName'],
      '_InlineImagePromptPage',
    );
  });

  testWidgets('前台才跑心跳，离开前台写出汇总', (tester) async {
    final binding = tester.binding;
    addTearDown(recorder.uninstall);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recorder.install();
    recorder.handleTimings([_frame()]);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_meta(logs.single)['event'], 'frameSummary');

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 250));
    recorder.uninstall();
    await tester.pump(const Duration(milliseconds: 250));
  });

  testWidgets('页面名取最上层页面的类型，看不出来时为空', (tester) async {
    final observer = MoeDetailStackObserver();
    addTearDown(observer.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const SizedBox(),
      ),
    );
    expect(observer.topPageName, 'MainPage');

    navigator.currentState!.pushParallaxSlide<void>(page: const _DemoPage());
    await tester.pumpAndSettle();
    expect(observer.topPageName, '_DemoPage');

    navigator.currentState!.push<void>(
      PageRouteBuilder(pageBuilder: (_, _, _) => const SizedBox()),
    );
    await tester.pumpAndSettle();
    expect(observer.topPageName, isNull);
  });
}

class _DemoPage extends StatelessWidget {
  const _DemoPage();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
