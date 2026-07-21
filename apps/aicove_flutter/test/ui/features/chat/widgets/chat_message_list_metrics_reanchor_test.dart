import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

/// 复现并锁定「进入会话后尾部表情包异步解码长高 → 列表不再贴底」：
/// 同一 widget/state 下用可控 AssetBundle 延迟表情字节，绕开
/// didUpdateWidget 稳定化入口，专测纯渲染层 extent 变化的重锚路径
/// （任务 07-20-chat-entry-bottom-anchor，方案审查 B4 的测试契约）。

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._settings);

  final AppSettings _settings;

  @override
  Future<AppSettings> build() async => _settings;
}

AppSettings _buildSettings() {
  return const AppSettings(
    ttsEnabled: true,
    defaultModelName: 'deepseek-chat',
    defaultPersonaPrompt: '',
    modelList: <String>['deepseek-chat'],
    allKnownModels: <String>['deepseek-chat'],
    modelDisplayNames: <String, String>{},
    modelTypes: <String, String>{},
    modelConfigs: <String, ModelConfig>{},
    apiKey: '',
    apiBaseUrl: 'https://api.openai.com/v1',
    imageGenerationEnabled: false,
    maxFileUploadMB: 10,
    historyMessageLimit: 100,
    customModels: <CustomModel>[],
    providers: <ProviderAuth>[],
    modelProviderMap: <String, String>{},
    backendApiKey: '',
    messageChunkingEnabled: false,
    messageFormatConfig: MessageFormatConfig(enableChunking: false),
    textScaleFactor: 1.0,
    uiScaleFactor: 1.0,
    imagePreviewScale: 1.0,
    autoReplySettings: AutoReplySettings(),
    globalBackgroundColor: GlobalBackgroundColor.white,
    chatBackgroundColor: ChatBackgroundColor.defaultColor,
    isDarkMode: false,
    useSystemTheme: true,
    accentColor: 'FC96AA',
    hideUserAvatar: false,
  );
}

/// 可控 AssetBundle：manifest 立即返回；表情 PNG 的字节由各自 Completer 门控，
/// 使表情在「首帧高度≈0 → 放行后长高」之间可精确切换，且不产生任何
/// didUpdateWidget（消息数据全程不变）。
class _GatedStickerBundle extends CachingAssetBundle {
  _GatedStickerBundle(this.stickerKeys);

  final List<String> stickerKeys;
  final Map<String, Completer<ByteData>> gates =
      <String, Completer<ByteData>>{};
  final List<String> loadRequestedKeys = <String>[];

  Completer<ByteData> gateFor(String key) =>
      gates.putIfAbsent(key, Completer<ByteData>.new);

  @override
  Future<ByteData> load(String key) {
    loadRequestedKeys.add(key);
    if (key == 'AssetManifest.bin') {
      final manifest = const StandardMessageCodec().encodeMessage(
        <String, Object?>{
          for (final stickerKey in stickerKeys) stickerKey: <Object?>[],
        },
      )!;
      return SynchronousFuture<ByteData>(manifest);
    }
    if (gates.containsKey(key) || stickerKeys.contains(key)) {
      return gateFor(key).future;
    }
    return Future<ByteData>.error(
      FlutterError('unexpected asset in test bundle: $key'),
    );
  }
}

ByteData _buildStickerPngBytes({int width = 120, int height = 120}) {
  final bytes = img.encodePng(img.Image(width: width, height: height));
  return ByteData.sublistView(bytes);
}

List<Message> _buildBaseMessages(int count) {
  final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
  final longText = List.filled(12, '用于撑高列表').join('，');
  return List<Message>.generate(count, (index) {
    return Message.text(
      id: 'm_$index',
      role: index.isEven ? 'assistant' : 'user',
      content: '第$index条消息：$longText',
      createdAt: baseTime.add(Duration(minutes: index)),
      status: 'sent',
    );
  });
}

Message _buildStickerMessage({
  required String id,
  required String assetKey,
  required DateTime createdAt,
}) {
  return Message(
    id: id,
    role: 'assistant',
    content: '',
    blocks: <MessageBlock>[
      EmojiBlock(
        id: 'eb_$id',
        messageId: id,
        emojiId: 'emoji_$id',
        path: assetKey,
      ),
    ],
    createdAt: createdAt,
    status: 'sent',
  );
}

/// 同一条尾消息携带多个门控表情 block：用于「跨帧多次长高」用例——
/// 多次纯渲染层长高发生在同一 active sliver 项内，不引入任何结构性
/// 消息变化（v3 裁决后结构变化会关闭入场收敛窗）。
Message _buildMultiStickerMessage({
  required String id,
  required List<String> assetKeys,
  required DateTime createdAt,
}) {
  return Message(
    id: id,
    role: 'assistant',
    content: '',
    blocks: <MessageBlock>[
      for (var i = 0; i < assetKeys.length; i++)
        EmojiBlock(
          id: 'eb_${id}_$i',
          messageId: id,
          emojiId: 'emoji_${id}_$i',
          path: assetKeys[i],
        ),
    ],
    createdAt: createdAt,
    status: 'sent',
  );
}

class _StickerTailHarness extends StatefulWidget {
  const _StickerTailHarness({
    super.key,
    required this.stickerAssetKeys,
    this.tailMultiBlockAssetKeys,
    this.baseMessageCount = 30,
    this.onDebugAutoScrollRequested,
    this.onLoadMore,
    this.hasMoreMessages = false,
  });

  final List<String> stickerAssetKeys;

  /// 非空时在尾部追加一条「多表情 block」消息（各 block 独立门控）。
  final List<String>? tailMultiBlockAssetKeys;

  /// 初始文本消息条数：0＝空时间线（R2 专项）；小值＝短历史（R3a 分页刺激）。
  final int baseMessageCount;
  final ValueChanged<String>? onDebugAutoScrollRequested;
  final Future<void> Function()? onLoadMore;
  final bool hasMoreMessages;

  @override
  State<_StickerTailHarness> createState() => _StickerTailHarnessState();
}

class _StickerTailHarnessState extends State<_StickerTailHarness> {
  late List<Message> _messages;
  List<Message> _transientMessages = const <Message>[];
  late final ChatViewportController _viewportController;
  bool _isLoadingMore = false;
  bool _hasMoreMessages = false;

  ChatViewportController get viewportController => _viewportController;

  @override
  void initState() {
    super.initState();
    _viewportController = ChatViewportController();
    _hasMoreMessages = widget.hasMoreMessages;
    final base = _buildBaseMessages(widget.baseMessageCount);
    final tailTime =
        base.isNotEmpty ? base.last.createdAt : DateTime(2026, 1, 1, 12, 0, 0);
    final multiBlockKeys = widget.tailMultiBlockAssetKeys;
    _messages = <Message>[
      ...base,
      for (var i = 0; i < widget.stickerAssetKeys.length; i++)
        _buildStickerMessage(
          id: 'sticker_$i',
          assetKey: widget.stickerAssetKeys[i],
          createdAt: tailTime.add(Duration(minutes: i + 1)),
        ),
      if (multiBlockKeys != null)
        _buildMultiStickerMessage(
          id: 'sticker_multi',
          assetKeys: multiBlockKeys,
          createdAt: tailTime.add(
            Duration(minutes: widget.stickerAssetKeys.length + 1),
          ),
        ),
    ];
  }

  @override
  void dispose() {
    _viewportController.dispose();
    super.dispose();
  }

  /// 追加一条纯文本 assistant 消息：制造「实质性结构变化」，
  /// 用于验证入场收敛窗关闭后的负向语义。
  void appendTextMessage({required String id}) {
    final tailTime = _messages.last.createdAt;
    setState(() {
      _messages = <Message>[
        ..._messages,
        Message.text(
          id: id,
          role: 'assistant',
          content: List.filled(12, '结构性追加的新消息').join('，'),
          createdAt: tailTime.add(const Duration(minutes: 1)),
          status: 'sent',
        ),
      ];
    });
  }

  /// 以全新实例重建整份消息列表（ID/内容/顺序完全不变）：
  /// 模拟真机上「入库回流的同内容新实例列表」，不得关闭入场收敛窗（R1 正判据）。
  void refreshMessagesWithNewInstances() {
    setState(() {
      _messages = _messages
          .map(
            (m) => Message(
              id: m.id,
              role: m.role,
              content: m.content,
              blocks: m.blocks,
              createdAt: m.createdAt,
              status: m.status,
            ),
          )
          .toList();
    });
  }

  /// 等长替换中间一条消息的 ID：首尾指纹不变的实质性结构变化，
  /// 必须关闭入场收敛窗（R1 反判据，审查指出旧判据在此漏判）。
  void replaceMiddleMessageId() {
    final index = _messages.length ~/ 2;
    final origin = _messages[index];
    setState(() {
      _messages = <Message>[
        for (var i = 0; i < _messages.length; i++)
          if (i == index)
            Message.text(
              id: '${origin.id}_replaced',
              role: origin.role,
              content: origin.content,
              createdAt: origin.createdAt,
              status: origin.status,
            )
          else
            _messages[i],
      ];
    });
  }

  /// 设置临时（流式）消息：R2 空时间线首条消息经 didUpdateWidget 到达的入口。
  void setTransientMessages(List<Message> value) {
    setState(() => _transientMessages = value);
  }

  void setLoadingMore(bool value) {
    setState(() => _isLoadingMore = value);
  }

  void prependOlderMessages({int count = 5}) {
    final oldest = _messages.first;
    final older = List<Message>.generate(count, (index) {
      final messageIndex = count - index;
      return Message.text(
        id: 'older_$messageIndex',
        role: 'assistant',
        content: '更早的历史消息 $messageIndex：${List.filled(12, '内容').join('，')}',
        createdAt: oldest.createdAt.subtract(Duration(minutes: messageIndex)),
        status: 'sent',
      );
    });
    setState(() {
      _messages = <Message>[...older, ..._messages];
      _hasMoreMessages = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: 'conv_metrics_reanchor',
      messages: _messages,
      transientMessages: _transientMessages,
      displayName: '测试AI',
      avatarUrl: null,
      viewportController: _viewportController,
      onLoadMore: widget.onLoadMore,
      isLoadingMore: _isLoadingMore,
      hasMoreMessages: _hasMoreMessages,
      onDebugAutoScrollRequested: widget.onDebugAutoScrollRequested,
    );
  }
}

Widget _buildHost({
  required _GatedStickerBundle bundle,
  required GlobalKey<_StickerTailHarnessState> harnessKey,
  required List<String> stickerAssetKeys,
  List<String>? tailMultiBlockAssetKeys,
  int baseMessageCount = 30,
  ValueChanged<String>? onDebugAutoScrollRequested,
  Future<void> Function()? onLoadMore,
  bool hasMoreMessages = false,
  double viewportHeight = 520,
}) {
  final settings = _buildSettings();
  return ProviderScope(
    overrides: [
      appSettingsProvider
          .overrideWith(() => _FakeAppSettingsNotifier(settings)),
    ],
    child: SkinScope(
      skin: const MoeTalkSkin(),
      child: MaterialApp(
        home: DefaultAssetBundle(
          bundle: bundle,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: viewportHeight,
                child: _StickerTailHarness(
                  key: harnessKey,
                  stickerAssetKeys: stickerAssetKeys,
                  tailMultiBlockAssetKeys: tailMultiBlockAssetKeys,
                  baseMessageCount: baseMessageCount,
                  onDebugAutoScrollRequested: onDebugAutoScrollRequested,
                  onLoadMore: onLoadMore,
                  hasMoreMessages: hasMoreMessages,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

double _distanceToBottom(ScrollController controller) {
  final position = controller.position;
  return position.pixels - position.minScrollExtent;
}

ScrollController _controllerOf(WidgetTester tester) {
  final listFinder = find.byType(CustomScrollView);
  expect(listFinder, findsOneWidget);
  return tester.widget<CustomScrollView>(listFinder).controller!;
}

/// 按 asset 名找表情 Image。skipOffstage 必须为 false：列表 cacheExtent
/// 区（已构建未绘制）与入场动画 0 高帧的组件都会被默认 finder 判为
/// offstage 而「隐身」——此前两个用例 finder=0 的真凶正是这个默认值，
/// 组件与解码链路其实全程健在。
Finder _stickerImageFinder(String assetKey) {
  return find.byWidgetPredicate(
    (widget) =>
        widget is Image &&
        widget.image is AssetImage &&
        (widget.image as AssetImage).assetName == assetKey,
    skipOffstage: false,
  );
}

double _stickerRenderedHeight(WidgetTester tester, String assetKey) {
  final imageFinder = _stickerImageFinder(assetKey);
  expect(imageFinder, findsOneWidget);
  return tester.getSize(imageFinder).height;
}

/// 放行表情字节并等待真实解码生效。
///
/// 门的 complete 必须放进 runAsync（真实事件循环）里执行，否则解码链路
/// 跨 fake/real zone 偶发进 errorBuilder（全量并跑时的机器负载差异会放大）。
/// 解码完成用「有界收敛等待」而非固定延时：每轮真实小睡＋补一帧，直到
/// 表情长高或轮数耗尽（≤20 轮，有界超时）。growth 确认后再补的帧序保持
/// 显式（不用 pumpAndSettle 掩盖「实现没请求下一帧」的缺陷，方案审查 B1/B4）。
Future<void> _completeStickerAndPump(
  WidgetTester tester,
  _GatedStickerBundle bundle,
  String assetKey,
  ByteData pngBytes, {
  bool waitForGrowth = true,
}) async {
  await tester.runAsync(() async {
    bundle.gateFor(assetKey).complete(pngBytes);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  if (waitForGrowth) {
    var grown = false;
    var lastFinderCount = -1;
    double lastHeight = -1;
    for (var attempt = 0; attempt < 20 && !grown; attempt++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      final imageFinder = _stickerImageFinder(assetKey);
      final elements = imageFinder.evaluate();
      lastFinderCount = elements.length;
      lastHeight =
          elements.isNotEmpty ? tester.getSize(imageFinder).height : -1;
      grown = lastFinderCount > 0 && lastHeight > 100;
    }
    expect(
      grown,
      isTrue,
      reason: '表情应在有界等待内完成解码长高（测试刺激前提）；'
          '末轮 finder=$lastFinderCount 高度=$lastHeight，'
          '树内全部 Image=${tester.widgetList<Image>(find.byType(Image, skipOffstage: false)).map((w) => w.image).toList()}，'
          'load 请求序列=${bundle.loadRequestedKeys}，'
          '门状态=${bundle.gates.map((k, v) => MapEntry(k, v.isCompleted))}',
    );
  } else {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
  }
  await tester.pump();
  // ScrollMetricsNotification 在帧后 microtask 派发；这个真实异步间隙
  // 让通知与（若实现正确）当场 jump 都发生，再补一帧反映最终位置。
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() async {
    previousPathProvider = PathProviderPlatform.instance;
    tempDir = await Directory.systemTemp.createTemp('chat_list_reanchor_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
  });

  tearDown(() async {
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  testWidgets('尾部表情异步解码长高后，follow-latest 应重锚回真实底部', (tester) async {
    const assetKey = 'assets/test_stickers/t1_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '初始置底应在表情解码前完成',
    );
    expect(
      _stickerRenderedHeight(tester, assetKey),
      lessThan(8),
      reason: '门控未放行时表情应接近零高（复现前提）',
    );
    autoScrollReasons.clear();

    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);

    expect(
      _stickerRenderedHeight(tester, assetKey),
      greaterThan(100),
      reason: '放行后表情应长高到实际尺寸（约 120px），否则测试刺激无效',
    );
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '纯渲染层长高后应重锚回底部：最后一条消息紧贴输入框上方',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isNotEmpty,
      reason: '重锚应经 metricsReanchor 路径执行（而非碰巧被其他路径拉回）',
    );
  });

  testWidgets('跨帧多次长高：同一尾消息两个表情分批解码，去重不吞后续收敛', (tester) async {
    const assetKey1 = 'assets/test_stickers/t2_e1.png';
    const assetKey2 = 'assets/test_stickers/t2_e2.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey1, assetKey2]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    // 两个门控表情放在同一条尾消息的两个 block 里：多次纯渲染层长高都
    // 发生在 active sliver 的同一项内，全程无结构性消息变化（v3 裁决后
    // 结构变化会关闭入场收敛窗，跨消息追加属于负向用例的职责）。
    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[],
        tailMultiBlockAssetKeys: const <String>[assetKey1, assetKey2],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(_distanceToBottom(controller), closeTo(0, 0.5));
    autoScrollReasons.clear();

    await _completeStickerAndPump(tester, bundle, assetKey1, pngBytes);
    expect(_stickerRenderedHeight(tester, assetKey1), greaterThan(100));
    final reanchorsAfterFirst =
        autoScrollReasons.where((r) => r == 'metricsReanchor').length;
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '第一次长高后应已收敛',
    );
    expect(
      reanchorsAfterFirst,
      greaterThanOrEqualTo(1),
      reason: '第一次长高应经 metricsReanchor 收敛；实际回调序列=$autoScrollReasons',
    );
    autoScrollReasons.clear();

    await _completeStickerAndPump(tester, bundle, assetKey2, pngBytes);
    expect(_stickerRenderedHeight(tester, assetKey2), greaterThan(100));
    final reanchorsAfterSecond =
        autoScrollReasons.where((r) => r == 'metricsReanchor').length;
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '第二个表情跨帧长高后仍应收敛到执行时最新底部',
    );
    expect(
      reanchorsAfterSecond,
      greaterThanOrEqualTo(1),
      reason: '跨帧再次长高允许再次重锚，去重不得吞掉后续收敛；'
          '实际回调序列=$autoScrollReasons',
    );
  });

  testWidgets('用户拖动脱离后表情解码长高，不得强拉回底部', (tester) async {
    const assetKey = 'assets/test_stickers/t3_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final listFinder = find.byType(CustomScrollView);
    // 手工手势上滑 300px：分步 move＋静置超过速度采样窗（~100ms）再抬手，
    // 抬手速度≈0，杜绝 tester.drag 的惯性 fling 把列表甩出 cacheExtent(500)
    // 导致尾部表情被虚拟化回收——位移需既超过脱离阈值、又让表情保持已构建。
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pump();

    final controller = _controllerOf(tester);
    final detachedDistance = _distanceToBottom(controller);
    expect(detachedDistance, greaterThan(120), reason: '上滑后应处于脱离状态');
    expect(
      _stickerRenderedHeight(tester, assetKey),
      lessThan(8),
      reason: '脱离后表情仍应在 cacheExtent 内保持已构建（长高刺激的前提）',
    );
    autoScrollReasons.clear();

    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);

    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '脱离（followLatest=false）时渲染层长高不得触发重锚',
    );
    expect(
      _distanceToBottom(controller),
      greaterThan(120),
      reason: '脱离位置不应被拉回底部（detached 补偿语义不变）',
    );
  });

  testWidgets('历史分页窗口内（锁先释放、pending 仍在）表情解码不得拉底，补历史语义不变', (tester) async {
    const assetKey = 'assets/test_stickers/t4_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();
    Completer<void>? pendingLoadMore;

    // 短历史（3 条）：历史顶仍在 cacheExtent(500) 内，门控尾表情全程保持
    // 已构建，使「分页窗口内的长高刺激」真实发生（审查 R3a：原版把表情
    // 拖出缓存区被虚拟化，刺激为空，守卫未被证明）。pending 守卫的单独
    // 隔离由守卫链顺序与代码审查保证（分页必经用户手势，手势本身也关窗）。
    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        baseMessageCount: 3,
        onDebugAutoScrollRequested: autoScrollReasons.add,
        hasMoreMessages: true,
        onLoadMore: () {
          final completer = Completer<void>();
          pendingLoadMore = completer;
          harnessKey.currentState!.setLoadingMore(true);
          return completer.future;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 手工手势上滑过冲（零抬手速度）：触发短历史加载更多，且位移可控。
    final listFinder = find.byType(CustomScrollView);
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(pendingLoadMore, isNotNull, reason: '短历史上滑过冲应触发加载更多');

    // 复刻「加载锁先释放、历史稍后补进」的窗口（对齐 auto_scroll_guard 基线时序）。
    harnessKey.currentState!.setLoadingMore(false);
    pendingLoadMore!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    final controller = _controllerOf(tester);
    final distanceBeforeDecode = _distanceToBottom(controller);
    autoScrollReasons.clear();

    // 表情仍已构建（cacheExtent 内），放行后必须真实长高——刺激有效性断言。
    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);
    expect(
      _stickerRenderedHeight(tester, assetKey),
      greaterThan(100),
      reason: '放行后表情应真实长高（审查 R3a：刺激有效性前提）',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '历史分页恢复优先：该窗口内渲染层长高不得触发重锚',
    );
    expect(
      _distanceToBottom(controller),
      greaterThanOrEqualTo(distanceBeforeDecode - 0.5),
      reason: '视口不得被拉向底部（长高只应扩大与底部的距离）',
    );

    harnessKey.currentState!.prependOlderMessages();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '补进历史后视口应停留在历史侧（既有语义不变）',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
    );
  });

  testWidgets('视口尺寸变化（模拟键盘收起）：follow-latest 最终贴底，脱离状态不受影响', (tester) async {
    const assetKey = 'assets/test_stickers/t5_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    Widget hostWithHeight(double height) => _buildHost(
          bundle: bundle,
          harnessKey: harnessKey,
          stickerAssetKeys: const <String>[assetKey],
          onDebugAutoScrollRequested: autoScrollReasons.add,
          viewportHeight: height,
        );

    await tester.pumpWidget(hostWithHeight(520));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);
    final controller = _controllerOf(tester);
    expect(_distanceToBottom(controller), closeTo(0, 0.5));

    // follow-latest：视口高度变化后仍应稳定贴底（无论经重锚还是本就无位移）。
    await tester.pumpWidget(hostWithHeight(380));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: 'follow-latest 下视口尺寸变化后应贴底',
    );

    // 脱离后再变化视口：不得触发重锚。
    final listFinder = find.byType(CustomScrollView);
    await tester.drag(listFinder, const Offset(0, 600));
    await tester.pump();
    expect(_distanceToBottom(controller), greaterThan(120));
    autoScrollReasons.clear();

    await tester.pumpWidget(hostWithHeight(520));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '脱离状态下视口尺寸变化不得触发重锚',
    );
  });

  testWidgets('入场收敛窗关闭后（结构性追加），渲染层长高不得再触发重锚', (tester) async {
    const assetKey = 'assets/test_stickers/t6_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(_distanceToBottom(controller), closeTo(0, 0.5));
    autoScrollReasons.clear();

    // 结构性追加一条文本消息：实质性时间线变化（length/尾 id 变化）关闭
    // 入场收敛窗。既有产品裁决（auto_scroll_guard 锁定）：贴底时新 AI 消息
    // 不拉底——列表组件不得发起任何显式回底请求。
    harnessKey.currentState!.appendTextMessage(id: 'appended_text');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      autoScrollReasons,
      isEmpty,
      reason: '结构性追加不得触发任何显式回底请求（含 metricsReanchor）；'
          '实际回调序列=$autoScrollReasons',
    );
    expect(
      _distanceToBottom(controller),
      greaterThan(40),
      reason: '贴底时新消息不拉底（与 auto_scroll_guard 基线语义一致）',
    );

    // 窗口已关：此时表情解码长高（原尾消息已随分界移入 history sliver，
    // 长高只扩 max 天然不位移）不得再走 metricsReanchor。
    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);
    expect(
      _stickerRenderedHeight(tester, assetKey),
      greaterThan(100),
      reason: '放行后表情应真实长高（刺激有效性前提）',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '入场收敛窗关闭后，渲染层长高不得再由 metricsReanchor 接管',
    );
  });

  testWidgets('同 ID 新实例刷新不关窗：刷新后表情解码仍应重锚（R1 正判据）', (tester) async {
    const assetKey = 'assets/test_stickers/t7_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(_distanceToBottom(controller), closeTo(0, 0.5));
    autoScrollReasons.clear();

    // 模拟真机「入库回流的同内容新实例列表」：ID 序列不变，仅实例刷新。
    harnessKey.currentState!.refreshMessagesWithNewInstances();
    await tester.pump();
    await tester.pump();
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '同 ID 刷新本身无位移，不应触发重锚',
    );

    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);
    expect(_stickerRenderedHeight(tester, assetKey), greaterThan(100));
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '刷新不得误关入场收敛窗：其后的解码长高仍应重锚回底（R1 正判据）',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isNotEmpty,
    );
  });

  testWidgets('等长中间换 ID 关窗：替换后表情解码不得重锚（R1 反判据）', (tester) async {
    const assetKey = 'assets/test_stickers/t8_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(_distanceToBottom(_controllerOf(tester)), closeTo(0, 0.5));
    autoScrollReasons.clear();

    // 等长替换中间一条消息的 ID：首尾指纹不变——审查 R1 指出旧判据
    // （length/首尾 id）在此漏判，全序列比较必须识别为实质性结构变化。
    harnessKey.currentState!.replaceMiddleMessageId();
    await tester.pump();
    await tester.pump();
    autoScrollReasons.clear();

    await _completeStickerAndPump(tester, bundle, assetKey, pngBytes);
    expect(_stickerRenderedHeight(tester, assetKey), greaterThan(100));
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '等长中间换 ID 属实质性结构变化，必须关窗；'
          '其后的渲染层长高不得再由 metricsReanchor 接管（R1 反判据）',
    );
  });

  testWidgets('空时间线首条临时消息：入场动画全程（含长帧跨越完成）不得触发重锚（R2）', (tester) async {
    final bundle = _GatedStickerBundle(const <String>[]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[],
        baseMessageCount: 0,
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    autoScrollReasons.clear();

    // 空会话首条流式临时消息经 didUpdateWidget 到达：入场收敛窗会在其
    // 入场动画结束前开启，动画期的结构性长高必须被动画完成事实静默
    // （审查 R2：粗帧/长帧推进验证——不依赖固定时长猜测）。
    harnessKey.currentState!.setTransientMessages(<Message>[
      Message.text(
        id: 'temp_first',
        role: 'assistant',
        content: List.filled(10, '空会话首条流式内容').join('，'),
        createdAt: DateTime(2026, 1, 1, 12, 0, 0),
        status: 'sending',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 单个长帧直接跨越动画完成点（220ms）：完成帧自身的布局增长通知
    // 也必须被静默（完成回调经 post-frame+microtask 晚于该通知失效）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: '入场动画期（含完成帧）的结构性长高不得触发 metricsReanchor；'
          '实际回调序列=$autoScrollReasons',
    );
  });

  testWidgets('回底动画期间解码长高 metrics 不介入，动画完成 follow-up 兜底收敛（R3b）',
      (tester) async {
    const assetKey = 'assets/test_stickers/t9_e1.png';
    final bundle = _GatedStickerBundle(const <String>[assetKey]);
    final harnessKey = GlobalKey<_StickerTailHarnessState>();
    final autoScrollReasons = <String>[];
    final pngBytes = _buildStickerPngBytes();

    await tester.pumpWidget(
      _buildHost(
        bundle: bundle,
        harnessKey: harnessKey,
        stickerAssetKeys: const <String>[assetKey],
        onDebugAutoScrollRequested: autoScrollReasons.add,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(_distanceToBottom(controller), closeTo(0, 0.5));
    autoScrollReasons.clear();

    // 产品真实路径：用户上滑脱离（关窗＋detached）→ 点「回到底部」→
    // 动画回底期间表情解码长高。本用例是行为级覆盖：真实路径中手势已
    // 先关窗，「无 metricsReanchor」由关窗＋programmatic 双重保证（复核
    // 注：programmatic 分支的单独归因不在此隔离）；核心契约是解码长高
    // 使首段动画目标过期后，最终收敛必须由动画完成后的 distance
    // follow-up 兜底（PRD v2 验收第 3 条、审查 R3b）。
    final listFinder = find.byType(CustomScrollView);
    final gesture = await tester.startGesture(tester.getCenter(listFinder));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, 50));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pump();
    final detachedDistance = _distanceToBottom(controller);
    expect(detachedDistance, greaterThan(120), reason: '上滑后应处于脱离状态');
    autoScrollReasons.clear();

    harnessKey.currentState!.viewportController.onJumpToLatest();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 动画进行中放行表情：真实解码（runAsync）＋帧推进，长高落在
    // programmatic 窗口内。
    await tester.runAsync(() async {
      bundle.gateFor(assetKey).complete(pngBytes);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    // 推进到第一段动画结束＋follow-up 第二段动画结束（各 ≤300ms 量级）。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump();

    expect(_stickerRenderedHeight(tester, assetKey), greaterThan(100));
    expect(
      autoScrollReasons.where((reason) => reason == 'viewportController'),
      isNotEmpty,
      reason: '回底动画应由 viewportController 请求发起',
    );
    expect(
      autoScrollReasons.where((reason) => reason == 'metricsReanchor'),
      isEmpty,
      reason: 'programmatic 期间的通知应被守卫跳过，不得经 metricsReanchor 收敛',
    );
    expect(
      _distanceToBottom(controller),
      closeTo(0, 0.5),
      reason: '动画完成后的 distance follow-up 必须把跳过的长高距离补收敛到底',
    );
  });
}
