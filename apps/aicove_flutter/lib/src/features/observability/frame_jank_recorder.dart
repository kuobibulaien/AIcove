import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'frontend_diagnostics_port.dart';
import 'frontend_diagnostics_service.dart';

/// 常驻卡顿记录：逐帧只累加固定直方图，日志只写分钟汇总和限频样本。
///
/// 只在主引擎的前台运行。帧数据由引擎批量回传（Release 约每秒一批），所以样本
/// 记录的是回传时刻，真实发生时间用 frameAgeMs 反推。事件循环延迟只说明主线程
/// 当时没轮到定时器，不等于一定是应用代码占住了它。
class FrameJankRecorder with WidgetsBindingObserver {
  FrameJankRecorder(this._diagnostics);

  static final FrameJankRecorder instance = FrameJankRecorder(
    FrontendDiagnosticsService.instance,
  );

  static const unknownPage = 'unknown';
  static const mixedPage = 'mixed';
  static const _window = Duration(seconds: 60);
  static const _beat = Duration(milliseconds: 100);
  static const _stallThreshold = Duration(milliseconds: 150);
  static const _suspendedThreshold = Duration(seconds: 60);
  static const _slowFrameUs = 100000;
  static const _maxSamplesPerWindow = 10;

  final FrontendDiagnosticsPort _diagnostics;
  final _syncSpans = Queue<(String, int, int)>();
  final _phaseSpans = Queue<(String, int, int)>();
  final _activePhases = <String, List<int>>{};

  T traceSync<T>(String tag, T Function() action) {
    final start = DateTime.now().microsecondsSinceEpoch;
    try {
      return action();
    } finally {
      recordSyncSpan(tag, start, DateTime.now().microsecondsSinceEpoch);
    }
  }

  void recordSyncSpan(String tag, int startWallUs, int endWallUs) {
    if (endWallUs - startWallUs < 8000) return;
    if (_syncSpans.length == 32) _syncSpans.removeFirst();
    _syncSpans.addLast((tag, startWallUs, endWallUs));
  }

  void enterPhase(String phase) {
    (_activePhases[phase] ??= []).add(DateTime.now().microsecondsSinceEpoch);
  }

  void exitPhase(String phase) {
    final starts = _activePhases[phase];
    if (starts == null || starts.isEmpty) return;
    final start = starts.removeLast();
    if (starts.isEmpty) _activePhases.remove(phase);
    if (_phaseSpans.length == 32) _phaseSpans.removeFirst();
    _phaseSpans.addLast((phase, start, DateTime.now().microsecondsSinceEpoch));
  }

  Map<String, Object?> _attribution(int start, int end) {
    final phases = <String>{};
    for (final (phase, from, to) in _phaseSpans) {
      if (from <= end && to >= start) phases.add(phase);
    }
    for (final entry in _activePhases.entries) {
      if (entry.value.any((from) => from <= end)) phases.add(entry.key);
    }
    final spans = _syncSpans.where((s) => s.$2 <= end && s.$3 >= start).toList()
      ..sort((a, b) => (b.$3 - b.$2).compareTo(a.$3 - a.$2));
    return {
      if (phases.isNotEmpty) 'activePhases': phases.toList(),
      if (spans.isNotEmpty)
        'syncSpans': [
          for (final s in spans.take(6))
            {'tag': s.$1, 'ms': (s.$3 - s.$2) / 1000},
        ],
    };
  }

  /// 由应用壳提供当前页面的固定名称，不含用户数据。
  String? Function()? pageName;

  final _windowClock = Stopwatch();
  final _beatClock = Stopwatch();
  final _ui = _FrameHistogram();
  final _raster = _FrameHistogram();
  final _total = _FrameHistogram();
  Timer? _beatTimer;
  bool _installed = false;
  bool _foreground = true;
  int _serial = 0;
  int _frames = 0;
  int _overBudget = 0;
  int _slowFrames = 0;
  int _stalls = 0;
  int _stallTotalMs = 0;
  int _stallMaxMs = 0;
  int _samples = 0;
  int _suppressed = 0;
  double? _refreshHz;
  String? _windowPage;
  bool _windowMixed = false;
  String? _lastBatchPage;

  void install() {
    if (_installed) return;
    _installed = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    binding.addTimingsCallback(handleTimings);
    _windowClock
      ..reset()
      ..start();
    final state = binding.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    if (_foreground) _startBeat();
  }

  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _stopBeat();
    final binding = WidgetsBinding.instance;
    binding.removeObserver(this);
    binding.removeTimingsCallback(handleTimings);
    _windowClock.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _lastBatchPage = null;
      _windowClock
        ..reset()
        ..start();
      _startBeat();
      return;
    }
    _stopBeat();
    flushWindow();
  }

  void _startBeat() {
    _beatTimer?.cancel();
    _beatClock
      ..reset()
      ..start();
    _beatTimer = Timer(_beat, _onBeat);
  }

  void _stopBeat() {
    _beatTimer?.cancel();
    _beatTimer = null;
    _beatClock.stop();
  }

  void _onBeat() {
    handleBeatLateness(_beatClock.elapsed - _beat);
    if (_windowClock.elapsed >= _window) {
      flushWindow();
      _windowClock.reset();
    }
    _startBeat();
  }

  @visibleForTesting
  void handleBeatLateness(Duration lateness) {
    if (lateness < _stallThreshold || lateness >= _suspendedThreshold) return;
    final page = _currentPage();
    _trackPage(page);
    final ms = lateness.inMilliseconds;
    _stalls++;
    _stallTotalMs += ms;
    if (ms > _stallMaxMs) _stallMaxMs = ms;
    final now = DateTime.now().microsecondsSinceEpoch;
    _sample(FrontendStage.uiStall, page, {
      'stallMs': ms,
      ..._attribution(now - lateness.inMicroseconds - 100000, now),
    });
  }

  @visibleForTesting
  void handleTimings(List<FrameTiming> timings) {
    // 离开前台后才回传的帧归不到任何窗口，直接放弃。
    if (!_foreground) return;
    final page = _currentPage();
    _trackPage(page);
    // 一批帧可能跨过切页，此时无法确定某一帧属于哪个页面。
    final batchPage = _lastBatchPage == null || _lastBatchPage == page
        ? page
        : mixedPage;
    _lastBatchPage = page;
    final refreshHz =
        PlatformDispatcher.instance.displays.firstOrNull?.refreshRate;
    final budgetUs = refreshHz != null && refreshHz > 0
        ? 1000000 / refreshHz
        : null;
    if (budgetUs != null) _refreshHz = refreshHz;
    for (final timing in timings) {
      final uiUs = timing.buildDuration.inMicroseconds;
      final rasterUs = timing.rasterDuration.inMicroseconds;
      final totalUs = timing.totalSpan.inMicroseconds;
      _frames++;
      _ui.add(uiUs);
      _raster.add(rasterUs);
      _total.add(totalUs);
      if (budgetUs != null && (uiUs > budgetUs || rasterUs > budgetUs)) {
        _overBudget++;
      }
      if (totalUs < _slowFrameUs) continue;
      _slowFrames++;
      final finishedAtUs = timing.timestampInMicroseconds(
        FramePhase.rasterFinishWallTime,
      );
      final ageMs =
          (DateTime.now().microsecondsSinceEpoch - finishedAtUs) ~/ 1000;
      _sample(FrontendStage.slowFrame, batchPage, {
        'uiMs': uiUs ~/ 1000,
        'rasterMs': rasterUs ~/ 1000,
        'vsyncMs': timing.vsyncOverhead.inMilliseconds,
        'totalMs': totalUs ~/ 1000,
        if (ageMs >= 0) 'frameAgeMs': ageMs,
        ..._attribution(finishedAtUs - totalUs - 50000, finishedAtUs),
      });
    }
  }

  /// 写出本窗口汇总。窗口内没有帧也没有延迟时不写。
  @visibleForTesting
  void flushWindow() {
    if (_frames > 0 || _stalls > 0) {
      final rssMb = ProcessInfo.currentRss ~/ 1048576;
      final peakRssMb = ProcessInfo.maxRss ~/ 1048576;
      final imageCache = PaintingBinding.instance.imageCache;
      _record(
        FrontendStage.frameSummary,
        _windowMixed ? mixedPage : _windowPage ?? unknownPage,
        {
          'frames': _frames,
          'overBudgetFrames': _overBudget,
          'slowFrames': _slowFrames,
          'refreshHz': ?_refreshHz?.round(),
          if (_frames > 0) ...{
            'uiP50Ms': _ui.percentileMs(0.5),
            'uiP95Ms': _ui.percentileMs(0.95),
            'uiMaxMs': _ui.maxMs,
            'rasterP50Ms': _raster.percentileMs(0.5),
            'rasterP95Ms': _raster.percentileMs(0.95),
            'rasterMaxMs': _raster.maxMs,
            'totalP95Ms': _total.percentileMs(0.95),
            'totalMaxMs': _total.maxMs,
          },
          'stalls': _stalls,
          'stallTotalMs': _stallTotalMs,
          'stallMaxMs': _stallMaxMs,
          'suppressedSamples': _suppressed,
          if (rssMb > 0) 'rssMb': rssMb,
          if (peakRssMb > 0) 'peakRssMb': peakRssMb,
          'imageCacheMb': imageCache.currentSizeBytes ~/ 1048576,
        },
      );
    }
    _resetWindow();
  }

  void _resetWindow() {
    _ui.reset();
    _raster.reset();
    _total.reset();
    _frames = 0;
    _overBudget = 0;
    _slowFrames = 0;
    _stalls = 0;
    _stallTotalMs = 0;
    _stallMaxMs = 0;
    _samples = 0;
    _suppressed = 0;
    _windowPage = null;
    _windowMixed = false;
  }

  void _trackPage(String page) {
    _windowPage ??= page;
    if (_windowPage != page) _windowMixed = true;
  }

  String _currentPage() {
    try {
      return pageName?.call() ?? unknownPage;
    } catch (_) {
      return unknownPage;
    }
  }

  void _sample(FrontendStage stage, String page, Map<String, Object?> state) {
    if (_samples >= _maxSamplesPerWindow) {
      _suppressed++;
      return;
    }
    _samples++;
    _record(stage, page, state);
  }

  void _record(FrontendStage stage, String page, Map<String, Object?> state) {
    try {
      _diagnostics.record(
        FrontendDiagnosticContext(
          operationId:
              'jank_${DateTime.now().microsecondsSinceEpoch}_${++_serial}',
        ),
        stage,
        facts: DiagnosticFacts(pageName: page, state: state),
      );
    } catch (_) {
      /* 诊断失败不能影响界面。 */
    }
  }
}

/// 0.5ms 一格，放不下的帧落在最后一格，分位数此时封顶 200ms；真实最慢值看 maxMs。
class _FrameHistogram {
  static const _bucketUs = 500;
  final _buckets = Uint32List(400);
  int _count = 0;
  int _maxUs = 0;

  void add(int us) {
    final index = us ~/ _bucketUs;
    _buckets[index < _buckets.length ? index : _buckets.length - 1]++;
    _count++;
    if (us > _maxUs) _maxUs = us;
  }

  double get maxMs => _maxUs / 1000;

  double percentileMs(double fraction) {
    final target = (_count * fraction).ceil();
    var seen = 0;
    for (var i = 0; i < _buckets.length - 1; i++) {
      seen += _buckets[i];
      if (seen >= target) return (i + 1) * _bucketUs / 1000;
    }
    return _buckets.length * _bucketUs / 1000;
  }

  void reset() {
    _buckets.fillRange(0, _buckets.length, 0);
    _count = 0;
    _maxUs = 0;
  }
}
