/// 离线真机滚动探针：真实 ChatMessageList + 本地合成流，不发模型请求。
/// flutter run --profile --no-resident -d <device> -t tool/chat_scroll_probe.dart
/// 默认走真实 ChatActions 分段链路（内存 DB + 假模型）。
/// 单长气泡对照：追加 --dart-define=SEGMENTED=false
/// adb logcat -s flutter | grep ChatScrollProbe
/// 测完请用默认入口 flutter run --no-resident 恢复正常应用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

import 'chat_segmented_fixture.dart';

const _segmented = bool.fromEnvironment('SEGMENTED', defaultValue: true);
const _conversation = 'offline_scroll_probe';
const _tail = 'probe_tail';

class _ProbeSettings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
        ttsEnabled: false,
        defaultModelName: '',
        defaultPersonaPrompt: '',
        modelList: [],
        allKnownModels: [],
        modelDisplayNames: {},
        modelTypes: {},
        modelConfigs: {},
        apiKey: '',
        apiBaseUrl: '',
        imageGenerationEnabled: false,
        maxFileUploadMB: 10,
        contextWindowTokens: 272000,
        customModels: [],
        providers: [],
        modelProviderMap: {},
        backendApiKey: '',
        messageChunkingEnabled: false,
        messageFormatConfig: MessageFormatConfig(enableChunking: false),
        textScaleFactor: 1,
        uiScaleFactor: 1,
        imagePreviewScale: 1,
        autoReplySettings: AutoReplySettings(),
        globalBackgroundColor: GlobalBackgroundColor.white,
        chatBackgroundColor: ChatBackgroundColor.defaultColor,
        isDarkMode: false,
        useSystemTheme: false,
        accentColor: 'FC96AA',
        hideUserAvatar: false,
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_segmented) {
    final fixture = await SegmentedChatFixture.create();
    runApp(UncontrolledProviderScope(
      container: fixture.container,
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(home: Scaffold(body: _Probe(fixture: fixture))),
      ),
    ));
    return;
  }
  runApp(ProviderScope(
    overrides: [
      appSettingsProvider.overrideWith(_ProbeSettings.new),
      streamProjectionPolicyProvider.overrideWithValue(
        const StreamProjectionPolicy(useActiveStreamChannel: true),
      ),
    ],
    child: const SkinScope(
      skin: MoeTalkSkin(),
      child: MaterialApp(home: Scaffold(body: _Probe())),
    ),
  ));
}

class _Probe extends ConsumerStatefulWidget {
  const _Probe({this.fixture});
  final SegmentedChatFixture? fixture;
  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe> {
  final viewport = ChatViewportController();
  final clock = Stopwatch()..start();
  final timings = <FrameTiming>[];
  final messages = <Message>[
    for (var index = 0; index < 80; index++)
      Message.text(
        id: 'probe_$index',
        role: index.isEven ? 'assistant' : 'user',
        content: '第 $index 条历史消息：用于离线验证聊天列表在持续生成时是否跟手。',
        createdAt: DateTime(2026, 1, 1).add(Duration(minutes: index)),
      ),
    Message.fromBlocks(
      id: _tail,
      role: 'assistant',
      blocks: [TextBlock(messageId: _tail, content: '离线生成中')],
      createdAt: DateTime(2026, 1, 2),
      status: 'sending',
    ),
  ];
  Timer? stream;
  int epoch = 0;
  int builds = 0;
  String text = List.filled(12, '长回复测试：文本持续增长，手势应始终掌握阅读位置。').join('\n');
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

  void _publish() {
    if (!mounted) return;
    final fixture = widget.fixture;
    if (fixture != null) {
      epoch++;
      fixture.add(epoch % 8 == 0 ? '。' : '第$epoch次增量继续生成文字');
      return;
    }
    text += epoch % 6 == 0 ? '\n持续增长的下一行正文。' : '生成增量。';
    ref.read(activeStreamProjectionsProvider.notifier).publish(
          ActiveStreamProjection(
            conversationId: _conversation,
            generationSeq: 1,
            writeEpoch: ++epoch,
            tailMessageId: _tail,
            tailText: text,
            phase: ActiveStreamPhase.streamingTail,
          ),
        );
  }

  ScrollController _scrollController() {
    ScrollController? result;
    void visit(Element element) {
      if (element.widget case CustomScrollView(:final controller)) {
        result = controller;
        return;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return result!;
  }

  RenderBox? _visibleBubble(Size size) {
    RenderBox? result;
    void visit(Element element) {
      if (result != null) return;
      final key = element.widget.key;
      if (key is ValueKey<String> &&
          key.value.startsWith('message_bubble_') &&
          !key.value.startsWith('message_bubble_constraints_')) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.attached && box.hasSize) {
          final rect = box.localToGlobal(Offset.zero) & box.size;
          if (rect.bottom > size.height * 0.3 && rect.top < size.height * 0.7) {
            result = box;
            return;
          }
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return result;
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    while (mounted &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    await widget.fixture?.start();
    if (widget.fixture != null) viewport.onUserSend();
    _publish();
    stream =
        Timer.periodic(const Duration(milliseconds: 32), (_) => _publish());
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final scroll = _scrollController();
    final size = MediaQuery.sizeOf(context);
    var maxDragError = 0.0;
    var maxVisualDragError = 0.0;
    var visualSamples = 0;
    var lostAnchors = 0;
    var dragBuilds = 0;
    var movedSamples = 0;
    var detachedRounds = 0;
    final bubblesAddedWhileDragging = <int>[];
    final bubblesAddedDuringInertia = <int>[];
    final postJumpDistances = <double>[];
    final refreshRate = View.of(context).display.refreshRate;
    final frameBudgetUs = 1000000 / refreshRate;
    final dragWindows = <(int, int)>[];
    recording = true;
    for (var round = 0; round < 4 && mounted; round++) {
      viewport.onJumpToLatest();
      await Future<void>.delayed(const Duration(seconds: 1));
      postJumpDistances
          .add(scroll.position.pixels - scroll.position.minScrollExtent);
      final bubblesBeforeDrag = widget.fixture?.bubbles.length ?? 0;
      var point = Offset(size.width / 2, size.height * 0.45);
      final pointer = 100 + round;
      GestureBinding.instance.handlePointerEvent(PointerDownEvent(
        pointer: pointer,
        position: point,
        timeStamp: clock.elapsed,
      ));
      // 首步超过手势识别阈值，随后在列表内部小幅往返，不碰物理边界。
      await Future<void>.delayed(const Duration(milliseconds: 16));
      point += const Offset(0, 40);
      GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
        pointer: pointer,
        position: point,
        delta: const Offset(0, 40),
        timeStamp: clock.elapsed,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 16));
      // 识别拖动后，BouncingScrollPhysics 还有启动距离阈值。
      // 先越过这段框架死区，再测“已接管”期间的逐帧误差。
      point += const Offset(0, 16);
      GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
        pointer: pointer,
        position: point,
        delta: const Offset(0, 16),
        timeStamp: clock.elapsed,
      ));
      await SchedulerBinding.instance.endOfFrame;
      final anchor = _visibleBubble(size);
      final beforeBuilds = builds;
      final dragStart =
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      for (var frame = 0; frame < 120 && mounted; frame++) {
        final delta = frame % 40 < 20 ? 3.0 : -3.0;
        final previous = scroll.position.pixels;
        final previousTop = anchor != null && anchor.attached
            ? anchor.localToGlobal(Offset.zero).dy
            : null;
        point += Offset(0, delta);
        GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
          pointer: pointer,
          position: point,
          delta: Offset(0, delta),
          timeStamp: clock.elapsed,
        ));
        // 几何读数必须取本帧布局完成后的结果，不能用 16ms 定时器
        // 猜 vsync；否则 pixels 已更新但 RenderBox 还是上一帧。
        await SchedulerBinding.instance.endOfFrame;
        final actualDelta = scroll.position.pixels - previous;
        if (actualDelta.abs() > 0.5) movedSamples++;
        maxDragError = math.max(maxDragError, (actualDelta - delta).abs());
        if ((actualDelta - delta).abs() > 0.5) {
          debugPrint(
              '[ChatScrollProbe:motion] round=$round sample=$frame expected=$delta actual=$actualDelta');
        }
        if (previousTop != null && anchor != null && anchor.attached) {
          visualSamples++;
          maxVisualDragError = math.max(
              maxVisualDragError,
              (anchor.localToGlobal(Offset.zero).dy - previousTop - delta)
                  .abs());
        } else {
          lostAnchors++;
        }
      }
      dragBuilds += builds - beforeBuilds;
      dragWindows.add((
        dragStart,
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds
      ));
      if (viewport.isDetached) detachedRounds++;
      final bubblesBeforeInertia = widget.fixture?.bubbles.length ?? 0;
      bubblesAddedWhileDragging.add(bubblesBeforeInertia - bubblesBeforeDrag);
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(
        pointer: pointer,
        position: point,
        timeStamp: clock.elapsed,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      bubblesAddedDuringInertia.add(
        (widget.fixture?.bubbles.length ?? 0) - bubblesBeforeInertia,
      );
    }
    stream?.cancel();
    await widget.fixture?.finish();
    await Future<void>.delayed(const Duration(seconds: 1));
    recording = false;
    if (!mounted) return;
    double percentile(List<int> values) {
      values.sort();
      return values.isEmpty
          ? 0
          : values[((values.length - 1) * 0.95).round()] / 1000;
    }

    final dragTimings = timings.where((timing) {
      final stamp = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      return dragWindows
          .any((window) => stamp >= window.$1 && stamp <= window.$2);
    }).toList();
    final ui = timings.map((t) => t.buildDuration.inMicroseconds).toList();
    final raster = timings.map((t) => t.rasterDuration.inMicroseconds).toList();
    debugPrint('[ChatScrollProbe] ${jsonEncode({
          'valid': timings.isNotEmpty &&
              movedSamples > 400 &&
              visualSamples > 400 &&
              detachedRounds == 4 &&
              (widget.fixture == null ||
                  bubblesAddedWhileDragging.every((n) => n >= 3)),
          'behaviorPassed': lostAnchors == 0 &&
              maxVisualDragError <= 0.5 &&
              maxDragError <= 0.5 &&
              postJumpDistances.every((gap) => gap.abs() <= 0.5),
          'visualSamples': visualSamples,
          'lostAnchors': lostAnchors,
          'maxVisualDragErrorPx': maxVisualDragError,
          'scenario': widget.fixture == null
              ? 'singleGrowingBubble'
              : 'realSegmentedDelivery',
          'bubbles': widget.fixture?.bubbles.length ?? 1,
          'bubblesAddedWhileDragging': bubblesAddedWhileDragging,
          'bubblesAddedDuringInertia': bubblesAddedDuringInertia,
          'postJumpDistancesPx': postJumpDistances,
          'timelineEmissions': widget.fixture?.timelineEmissions,
          'frames': timings.length,
          'refreshRate': refreshRate,
          'dragFrames': dragTimings.length,
          'dragUiP95Ms': percentile(
              dragTimings.map((t) => t.buildDuration.inMicroseconds).toList()),
          'dragFramesOverBudget': dragTimings
              .where((t) =>
                  t.buildDuration.inMicroseconds > frameBudgetUs ||
                  t.rasterDuration.inMicroseconds > frameBudgetUs)
              .length,
          'movedSamples': movedSamples,
          'detachedRounds': detachedRounds,
          'textCharacters': widget.fixture?.characters ?? text.length,
          'uiP95Ms': percentile(ui),
          'rasterP95Ms': percentile(raster),
          'over16ms': timings
              .where((t) =>
                  t.buildDuration.inMicroseconds > 16667 ||
                  t.rasterDuration.inMicroseconds > 16667)
              .length,
          'maxDragErrorPx': maxDragError,
          'dragListRebuilds': dragBuilds,
          'width': size.width,
          'note': '本地合成模型输入；分段模式含真实 ChatActions、内存 DB、分段与占位流程；不含网络、图片解码及 TTS',
        })}');
  }

  @override
  void dispose() {
    stream?.cancel();
    recording = false;
    SchedulerBinding.instance.removeTimingsCallback(_record);
    viewport.dispose();
    if (widget.fixture != null) unawaited(widget.fixture!.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fixture = widget.fixture;
    if (fixture != null) {
      return ValueListenableBuilder<List<Message>>(
        valueListenable: fixture.timeline,
        builder: (context, messages, _) => ChatMessageList(
          conversationId: fixture.conversation.id,
          messages: messages,
          displayName: '真实分段离线测试',
          viewportController: viewport,
          hasMoreMessages: false,
          onDebugListItemCountChanged: (_) => builds++,
        ),
      );
    }
    return ChatMessageList(
      conversationId: _conversation,
      messages: messages,
      displayName: '离线滚动测试',
      viewportController: viewport,
      hasMoreMessages: false,
      onDebugListItemCountChanged: (_) => builds++,
    );
  }
}
