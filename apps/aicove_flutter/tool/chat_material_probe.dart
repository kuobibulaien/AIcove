/// Mac 窄屏聊天材质性能探针：壁纸 + 真实顶栏（含渐变模糊）+ 输入条材质 +
/// ChatMessageList，按材质比较四个场景的帧耗时。不发模型请求。
///
/// tool/flutterw run --profile -d macos -t tool/chat_material_probe.dart \
///   --dart-define=MATERIAL=frosted   # solid | frosted | liquid
/// 可选：--dart-define=DARK=true  --dart-define=REPEAT=3
/// 沙盒包读不到环境变量；对照多组时用 build macos --profile 带同样的 define
/// 构建，再直接启动 build/macos/Build/Products/Profile/AIcove.app 里的可执行文件。
/// 输出：[MaterialProbe] 开头的 JSON 行，跑完自动退出。
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
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/composer.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_wallpaper_background.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_chat_header.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';

const _materialName = String.fromEnvironment(
  'MATERIAL',
  defaultValue: 'frosted',
);
const _dark = bool.fromEnvironment('DARK');
const _repeat = int.fromEnvironment('REPEAT', defaultValue: 3);

/// 单块玻璃基准：空则跑聊天场景；premium | standard | minimal | noblur。
const _bench = String.fromEnvironment('BENCH');

// 运行期判断：编译期常量分支会让 AOT 摇树后崩溃（_window_macos.dart 的 _Rect）。
final _benchMode = _bench.isNotEmpty && Platform.numberOfProcessors > 0;

/// 玻璃拆分对照：all，或 header、composer、list 的逗号组合；其余部分退回模糊。
const _liquidParts = String.fromEnvironment('LIQ_PARTS', defaultValue: 'all');
const _conversation = 'material_probe';
const _tail = 'material_probe_tail';
const _windowSize = Size(400, 860);

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
    isDarkMode: _dark,
    useSystemTheme: false,
    accentColor: 'FC96AA',
    hideUserAvatar: false,
  );
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
  final colors = _dark ? MoeColors.dark() : MoeColors.light();
  runApp(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(_ProbeSettings.new),
        streamProjectionPolicyProvider.overrideWithValue(
          const StreamProjectionPolicy(useActiveStreamChannel: true),
        ),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MoeLiquidGlassService.wrapApp(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: _dark ? Brightness.dark : Brightness.light,
              extensions: [colors],
            ),
            home: _benchMode
                ? const _GlassBench()
                : MoeGlassTheme(
                    enabled: material != MoeSurfaceMaterial.solid,
                    useLiquidGlass: material == MoeSurfaceMaterial.liquid,
                    blurSigma: kDefaultGlassBlurSigma,
                    child: const _Probe(),
                  ),
          ),
        ),
      ),
    ),
  );
}

class _Probe extends ConsumerStatefulWidget {
  const _Probe();
  @override
  ConsumerState<_Probe> createState() => _ProbeState();
}

class _ProbeState extends ConsumerState<_Probe>
    with SingleTickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  bool spinning = false;
  final viewport = ChatViewportController();
  final input = TextEditingController();
  final focus = FocusNode();
  final clock = Stopwatch()..start();
  final timings = <FrameTiming>[];
  final messages = <Message>[
    for (var index = 0; index < 80; index++)
      Message.text(
        id: 'material_$index',
        role: index.isEven ? 'assistant' : 'user',
        content: index % 5 == 0
            ? '第 $index 条历史消息：稍长一些的段落，用来让气泡在顶栏和输入条下方经过时'
                  '覆盖更多的模糊区域，接近日常聊天的阅读场景。'
            : '第 $index 条历史消息',
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
  final _boundaryKey = GlobalKey();
  bool recording = false;
  int epoch = 0;
  String text = '';

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
    final rssBefore = ProcessInfo.currentRss;
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
      'rssDeltaMb': (ProcessInfo.currentRss - rssBefore) ~/ (1 << 20),
    };
  }

  /// 不触碰列表和输入框，只让一个小方块转动，测静态画面的单帧成本。
  Future<void> _spin() async {
    focus.unfocus();
    setState(() => spinning = true);
    spin.repeat();
    await _wait(4000);
    spin.stop();
    setState(() => spinning = false);
  }

  Future<void> _idle() async {
    focus.unfocus();
    await _wait(4000);
  }

  Future<void> _typing() async {
    focus.requestFocus();
    for (var i = 0; i < 30; i++) {
      input.text = '${input.text}字';
      input.selection = TextSelection.collapsed(offset: input.text.length);
      await _wait(150);
    }
    input.clear();
  }

  Future<void> _drag(int pointerBase) async {
    final size = MediaQuery.sizeOf(context);
    for (var round = 0; round < 3; round++) {
      final pointer = pointerBase + round;
      var point = Offset(size.width / 2, size.height * 0.35);
      GestureBinding.instance.handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: point,
          timeStamp: clock.elapsed,
        ),
      );
      // 下拉看旧消息（反向列表），再放手触发惯性。
      for (var frame = 0; frame < 45; frame++) {
        point += const Offset(0, 8);
        GestureBinding.instance.handlePointerEvent(
          PointerMoveEvent(
            pointer: pointer,
            position: point,
            delta: const Offset(0, 8),
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
    viewport.onJumpToLatest();
    await _wait(600);
  }

  Future<void> _streaming() async {
    viewport.onJumpToLatest();
    final timer = Timer.periodic(const Duration(milliseconds: 32), (_) {
      text += epoch % 6 == 0 ? '\n持续增长的下一行正文。' : '生成增量。';
      ref
          .read(activeStreamProjectionsProvider.notifier)
          .publish(
            ActiveStreamProjection(
              conversationId: _conversation,
              generationSeq: 1,
              writeEpoch: ++epoch,
              tailMessageId: _tail,
              tailText: text,
              phase: ActiveStreamPhase.streamingTail,
            ),
          );
    });
    await _wait(5000);
    timer.cancel();
  }

  Future<void> _run() async {
    await _wait(2500);
    final results = <Map<String, Object?>>[];
    // 第 0 轮预热：着色器编译、图片解码不计入。
    for (var pass = 0; pass <= _repeat && mounted; pass++) {
      final round = [
        await _measure('spin', _spin),
        await _measure('idle', _idle),
        await _measure('typing', _typing),
        await _measure('drag', () => _drag(100 + pass * 10)),
        await _measure('streaming', _streaming),
      ];
      if (pass == 0) continue;
      for (final result in round) {
        result['pass'] = pass;
        results.add(result);
        debugPrint(
          '[MaterialProbe] ${jsonEncode({'material': _materialName == 'liquid' && _liquidParts != 'all' ? 'liquid-$_liquidParts' : _materialName, 'dark': _dark, ...result})}',
        );
      }
    }
    await _snapshot();
    debugPrint('[MaterialProbe] done');
    await _wait(300);
    exit(0);
  }

  /// 静止在最新消息处截整窗合成结果，供改动前后逐像素对比。
  Future<void> _snapshot() async {
    focus.unfocus();
    viewport.onJumpToLatest();
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
      '${Directory.systemTemp.path}/material_probe_${_materialName}_${_dark ? 'dark' : 'light'}.png',
    );
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    debugPrint('[MaterialProbe] snapshot ${file.path}');
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
    spin.dispose();
    viewport.dispose();
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  Widget _part(String name, Widget child) {
    if (_materialName != 'liquid' ||
        _liquidParts == 'all' ||
        _liquidParts.split(',').contains(name)) {
      return child;
    }
    return MoeGlassTheme(
      enabled: true,
      blurSigma: kDefaultGlassBlurSigma,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.moeColors;
    final toolbarHeight = MoeChatHeader.heightFor(
      MediaQuery.textScalerOf(context),
    );
    final top =
        toolbarHeight +
        telegramChatHeaderVerticalInset * 2 +
        telegramChatHeaderGap +
        MediaQuery.paddingOf(context).top;
    return RepaintBoundary(
      key: _boundaryKey,
      child: Stack(
        children: [
          Positioned.fill(
            child: ChatWallpaperLayer(
              image: _dark
                  ? 'assets/wallpapers/catnap_dark.webp'
                  : 'assets/wallpapers/catnap_light.webp',
              fallbackColor: telegramChatBackground,
            ),
          ),
          Scaffold(
            backgroundColor: Colors.transparent,
            extendBodyBehindAppBar: true,
            resizeToAvoidBottomInset: false,
            appBar: _PartAppBar(
              part: _part,
              child: MoeChatHeader(
                showBackButton: true,
                nativeInset: 0,
                toolbarHeight: toolbarHeight,
                leading: const Icon(Icons.arrow_back),
                title: Text(
                  '材质探针',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: telegramChatHeaderTitleSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                actions: [
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.call_outlined),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
            body: Stack(
              children: [
                Positioned.fill(
                  child: _part(
                    'list',
                    ChatMessageList(
                      conversationId: _conversation,
                      messages: messages,
                      displayName: '材质探针',
                      viewportController: viewport,
                      hasMoreMessages: false,
                      topOverlayHeight: top,
                      bottomOverlayHeight: 76,
                    ),
                  ),
                ),
                if (spinning)
                  Center(
                    child: RotationTransition(
                      turns: spin,
                      child: Container(
                        width: 120,
                        height: 120,
                        color: Colors.pink,
                      ),
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _part(
                    'composer',
                    ComposerGlassLayer(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.add_rounded, color: colors.muted),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: input,
                                focusNode: focus,
                                decoration: const InputDecoration(
                                  hintText: '消息',
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                            ),
                            Icon(Icons.send_rounded, color: colors.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PartAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PartAppBar({required this.part, required this.child});

  final Widget Function(String, Widget) part;
  final MoeChatHeader child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) => part('header', child);
}

/// 壁纸上只放一块输入条大小的玻璃，用持续动画逼出每帧重绘，隔离单块玻璃成本。
class _GlassBench extends StatefulWidget {
  const _GlassBench();
  @override
  State<_GlassBench> createState() => _GlassBenchState();
}

class _GlassBenchState extends State<_GlassBench>
    with SingleTickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  final timings = <FrameTiming>[];

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    void record(List<FrameTiming> frames) => timings.addAll(frames);
    for (var pass = 1; pass <= 3; pass++) {
      timings.clear();
      SchedulerBinding.instance.addTimingsCallback(record);
      await Future<void>.delayed(const Duration(seconds: 4));
      SchedulerBinding.instance.removeTimingsCallback(record);
      final raster =
          timings.map((t) => t.rasterDuration.inMicroseconds).toList()..sort();
      debugPrint(
        '[MaterialProbe] ${jsonEncode({'material': 'bench-$_bench', 'scenario': 'spin', 'pass': pass, 'seconds': 4, 'frames': timings.length, 'fps': timings.length / 4, 'uiP50': 0, 'uiP95': 0, 'rasterP50': raster.isEmpty ? 0 : raster[raster.length ~/ 2] / 1000, 'rasterP95': raster.isEmpty ? 0 : raster[(raster.length * 0.95).floor()] / 1000, 'overBudgetPct': 0, 'rssMb': ProcessInfo.currentRss >> 20})}',
      );
    }
    exit(0);
  }

  @override
  void dispose() {
    scroll.dispose();
    viewport.dispose();
    spin.dispose();
    super.dispose();
  }

  final scroll = ScrollController();
  final viewport = ChatViewportController();

  @override
  Widget build(BuildContext context) {
    final quality = switch (_bench) {
      'standard' => GlassQuality.standard,
      'minimal' => GlassQuality.minimal,
      _ => GlassQuality.premium,
    };
    final spinner = Center(
      child: RotationTransition(
        turns: spin,
        child: Container(width: 120, height: 120, color: Colors.pink),
      ),
    );
    const wallpaper = Positioned.fill(
      child: ChatWallpaperLayer(
        image: 'assets/wallpapers/catnap_light.webp',
        fallbackColor: telegramChatBackground,
      ),
    );
    // header* 变体：真实顶栏；-edge 再让列表滚到顶栏下，亮出三层渐变模糊。
    if (_bench.contains('header')) {
      final withEdge = _bench.contains('edge');
      if (withEdge) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients && scroll.offset == 0) scroll.jumpTo(40);
        });
      }
      return MoeGlassTheme(
        enabled: true,
        useLiquidGlass: !_bench.startsWith('frosted'),
        blurSigma: kDefaultGlassBlurSigma,
        child: Stack(
          children: [
            wallpaper,
            Scaffold(
              backgroundColor: Colors.transparent,
              extendBodyBehindAppBar: true,
              appBar: MoeChatHeader(
                showBackButton: true,
                nativeInset: 0,
                toolbarHeight: 44,
                leading: const Icon(Icons.arrow_back),
                title: const Text('基准'),
                actions: [
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.call_outlined),
                  ),
                  IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
              body: Stack(
                children: [
                  if (_bench.contains('chatlist'))
                    ChatMessageList(
                      conversationId: _conversation,
                      messages: [
                        for (var index = 0; index < 60; index++)
                          Message.text(
                            id: 'bench_$index',
                            role: index.isEven ? 'assistant' : 'user',
                            content: '第 $index 条历史消息',
                            createdAt: DateTime(
                              2026,
                              1,
                              1,
                            ).add(Duration(minutes: index)),
                          ),
                      ],
                      displayName: '基准',
                      viewportController: viewport,
                      hasMoreMessages: false,
                      topOverlayHeight: 70,
                    )
                  else if (withEdge)
                    ListView.builder(
                      controller: scroll,
                      itemCount: 60,
                      itemBuilder: (context, index) => Container(
                        height: 48,
                        margin: const EdgeInsets.all(4),
                        color: Colors.primaries[index % 18].withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  spinner,
                  if (_bench.contains('input'))
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ComposerGlassLayer(
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: TextField(
                            autofocus: true,
                            decoration: InputDecoration(
                              hintText: '消息',
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        wallpaper,
        spinner,
        Positioned(
          left: 12,
          right: 12,
          bottom: 14,
          height: 58,
          child: AdaptiveGlass(
            shape: const LiquidRoundedSuperellipse(borderRadius: 29),
            quality: quality,
            settings: LiquidGlassSettings(
              thickness: 34,
              refractiveIndex: 1.5,
              blur: _bench == 'noblur' ? 0 : 8,
              glassColor: const Color(0x55F8F8F8),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}
