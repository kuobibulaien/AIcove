/// Mac 宽屏根界面材质性能探针：壁纸 + 宽屏左栏真实 MainPage（60 个会话），
/// 按材质比较静态、栏内动画、栏外动画、列表拖动四个场景的帧耗时。
/// 不读数据库、不发模型请求。
///
/// tool/flutterw build macos --profile -t tool/root_material_probe.dart \
///   --dart-define=MATERIAL=liquid   # solid | frosted | liquid
/// 可选：--dart-define=DARK=true  --dart-define=REPEAT=3  --dart-define=LABEL=xxx
/// 沙盒包读不到环境变量，变体一律用 dart-define 分别构建；运行时用
/// `open -g` 启动产物，窗口置顶但不抢焦点，跑完自动退出。
/// 输出：[RootProbe] 开头的 JSON 行（经 debugPrint 写到系统日志与标准输出）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:aicove_flutter/src/features/chat/application/chat_page_queries.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/ui/features/home/pages/main_page.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_adaptive_shell.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

const _materialName = String.fromEnvironment(
  'MATERIAL',
  defaultValue: 'liquid',
);
const _dark = bool.fromEnvironment('DARK');
const _repeat = int.fromEnvironment('REPEAT', defaultValue: 3);
const _label = String.fromEnvironment('LABEL');
const _windowSize = Size(1000, 720);
const _paneInset = 12.0;
const _paneWidth = 360.0;

class _ProbeConversations extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async {
    final now = DateTime(2026, 10, 17, 14, 30);
    return [
      for (var i = 0; i < 60; i++)
        Conversation(
          id: 'root_probe_$i',
          title: '角色 $i',
          displayName: '角色 $i',
          lastMessage: '第 $i 个会话的最后一条消息，长度接近日常聊天预览',
          lastMessageTime: now.subtract(Duration(minutes: i * 7)),
          unreadCount: i % 4 == 1 ? i : 0,
          createdAt: now,
          updatedAt: now.subtract(Duration(minutes: i * 7)),
        ),
    ];
  }
}

/// The real list warms entry messages from the database; the probe has none.
class _NoWarmupQueries extends ChatPageQueries {
  _NoWarmupQueries(super.ref);

  @override
  Future<void> warmEntryMessages(Iterable<String> conversationIds) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MoeLiquidGlassService.initialize();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: _windowSize, center: true),
    () async {
      // 被遮挡的窗口拿不到 vsync，测量会停住；置顶但不抢焦点。
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show(inactive: true);
    },
  );
  final material = MoeSurfaceMaterial.values.byName(_materialName);
  runApp(
    ProviderScope(
      overrides: [
        conversationsProvider.overrideWith(_ProbeConversations.new),
        chatPageQueriesProvider.overrideWith(_NoWarmupQueries.new),
      ],
      child: MoeLiquidGlassService.wrapApp(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: _dark ? Brightness.dark : Brightness.light,
            extensions: [_dark ? MoeColors.dark() : MoeColors.light()],
          ),
          home: MoeGlassTheme(
            enabled: material != MoeSurfaceMaterial.solid,
            useLiquidGlass: material == MoeSurfaceMaterial.liquid,
            blurSigma: kDefaultGlassBlurSigma,
            child: const _Probe(),
          ),
        ),
      ),
    ),
  );
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

enum _Spin { none, inside, outside }

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  _Spin spinning = _Spin.none;
  final clock = Stopwatch()..start();
  final timings = <FrameTiming>[];
  final _boundaryKey = GlobalKey();
  bool recording = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_record);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  void _record(List<FrameTiming> frames) {
    if (recording) timings.addAll(frames);
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<Map<String, Object?>> _measure(
    String scenario,
    Future<void> Function() body,
  ) async {
    await _wait(600);
    timings.clear();
    final started = clock.elapsedMilliseconds;
    recording = true;
    await body();
    await SchedulerBinding.instance.endOfFrame;
    recording = false;
    final seconds = (clock.elapsedMilliseconds - started) / 1000;
    if (!mounted) return const {};
    final budgetUs = 1000000 / View.of(context).display.refreshRate;
    List<int> phase(int Function(FrameTiming) pick) =>
        timings.map(pick).toList()..sort();
    double pct(List<int> sorted, double p) =>
        sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()] / 1000;
    final ui = phase((t) => t.buildDuration.inMicroseconds);
    final raster = phase((t) => t.rasterDuration.inMicroseconds);
    final over = timings
        .where(
          (t) =>
              t.buildDuration.inMicroseconds > budgetUs ||
              t.rasterDuration.inMicroseconds > budgetUs,
        )
        .length;
    return {
      'scenario': scenario,
      'seconds': double.parse(seconds.toStringAsFixed(2)),
      'frames': timings.length,
      'fps': double.parse((timings.length / seconds).toStringAsFixed(1)),
      'uiP50': pct(ui, 0.5),
      'uiP95': pct(ui, 0.95),
      'rasterP50': pct(raster, 0.5),
      'rasterP95': pct(raster, 0.95),
      'rasterMax': raster.isEmpty ? 0 : raster.last / 1000,
      'overBudgetPct': timings.isEmpty
          ? 0
          : double.parse((over * 100 / timings.length).toStringAsFixed(1)),
      'rssMb': ProcessInfo.currentRss ~/ (1 << 20),
    };
  }

  Future<void> _idle() => _wait(4000);

  Future<void> _spin(_Spin where) async {
    setState(() => spinning = where);
    spin.repeat();
    await _wait(4000);
    spin.stop();
    setState(() => spinning = _Spin.none);
  }

  /// Drags the conversation list inside the pane down and back up, with fling.
  Future<void> _drag(int pointerBase) async {
    final size = MediaQuery.sizeOf(context);
    for (var round = 0; round < 4; round++) {
      final pointer = pointerBase + round;
      final step = Offset(0, round.isEven ? -8 : 8);
      var point = Offset(
        _paneInset + _paneWidth / 2,
        size.height * (round.isEven ? 0.75 : 0.3),
      );
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: point,
          timeStamp: clock.elapsed,
        ),
      );
      for (var frame = 0; frame < 40; frame++) {
        point += step;
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: pointer,
            position: point,
            delta: step,
            timeStamp: clock.elapsed,
          ),
        );
        await SchedulerBinding.instance.endOfFrame;
      }
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: point,
          timeStamp: clock.elapsed,
        ),
      );
      await _wait(900);
    }
  }

  Future<void> _run() async {
    await _wait(2500);
    // 第 0 轮预热：着色器编译、图片解码不计入。
    for (var pass = 0; pass <= _repeat && mounted; pass++) {
      final round = [
        await _measure('idle', _idle),
        await _measure('spinInside', () => _spin(_Spin.inside)),
        await _measure('spinOutside', () => _spin(_Spin.outside)),
        await _measure('drag', () => _drag(100 + pass * 10)),
      ];
      if (pass == 0) continue;
      for (final result in round) {
        debugPrint(
          '[RootProbe] ${jsonEncode({'material': _materialName, 'label': _label, 'dark': _dark, 'pass': pass, ...result})}',
        );
      }
    }
    await _snapshot();
    debugPrint('[RootProbe] done');
    await _wait(300);
    exit(0);
  }

  /// 静止画面整窗截图，供两版逐像素对比。
  Future<void> _snapshot() async {
    await _wait(1500);
    if (!mounted) return;
    final boundary =
        _boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(
      pixelRatio: View.of(context).devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    final file = File(
      '${Directory.systemTemp.path}/root_probe_${_materialName}_${_label}_${_dark ? 'dark' : 'light'}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('[RootProbe] snapshot ${file.path}');
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    spin.dispose();
    super.dispose();
  }

  Widget _spinner() => RotationTransition(
    turns: spin,
    child: Container(width: 80, height: 80, color: Colors.pink),
  );

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: _boundaryKey,
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              _dark
                  ? 'assets/wallpapers/sakura_dark.webp'
                  : 'assets/wallpapers/sakura_light.webp',
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            left: _paneInset,
            top: _paneInset,
            bottom: _paneInset,
            width: _paneWidth,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MoeWorkspace(
                  navigatorKey: GlobalKey<NavigatorState>(),
                  isWide: true,
                  isDetail: false,
                  child: const MainPage(),
                ),
                if (spinning == _Spin.inside)
                  Align(
                    alignment: const Alignment(0, 0.5),
                    child: _spinner(),
                  ),
              ],
            ),
          ),
          if (spinning == _Spin.outside)
            Positioned(right: 200, top: 300, child: _spinner()),
        ],
      ),
    );
  }
}
