import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

/// G2.1 followLatest 场景组（翻默认 true 前置清单第 5 条）：
/// 活跃流通道驱动的「气泡局部增高」在各视口状态下的贴底/锚点语义。
/// 程序滚动争抢场景（清单 5-4）由既有 auto_scroll_guard 套件的
/// programmatic 用例覆盖——窄信号与其共用同一组守卫旗标（_isProgrammaticScroll 等）。

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
    contextWindowTokens: 272000,
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

const String _kConvId = 'conv_stream_follow';
const String _kStreamShellId = 'm_stream_shell';

List<Message> _buildMessages({int historyCount = 14}) {
  final baseTime = DateTime(2026, 1, 1, 12, 0, 0);
  final history = List<Message>.generate(historyCount, (index) {
    final role = index.isEven ? 'assistant' : 'user';
    final id = 'm_$index';
    return Message.fromBlocks(
      id: id,
      role: role,
      blocks: <MessageBlock>[
        TextBlock(messageId: id, content: '历史消息内容第$index条，用于撑高列表方便滚动。'),
      ],
      createdAt: baseTime.add(Duration(minutes: index)),
      status: 'sent',
    );
  });
  // 活跃尾壳：assistant sending + 单 TextBlock（非分段活跃尾的物化形态）
  final shell = Message.fromBlocks(
    id: _kStreamShellId,
    role: 'assistant',
    blocks: <MessageBlock>[
      TextBlock(messageId: _kStreamShellId, content: '壳'),
    ],
    createdAt: baseTime.add(Duration(minutes: historyCount)),
    status: 'sending',
  );
  return [...history, shell];
}

class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double bottomOverlayHeight = 0;
  int listBuildCount = 0;
  final viewportController = ChatViewportController();
  List<Message> messages = _buildMessages();

  void setMessages(List<Message> value) => setState(() => messages = value);

  @override
  void dispose() {
    viewportController.dispose();
    super.dispose();
  }

  void setOverlay(double value) => setState(() => bottomOverlayHeight = value);

  @override
  Widget build(BuildContext context) {
    return ChatMessageList(
      conversationId: _kConvId,
      messages: messages,
      displayName: '测试AI',
      avatarUrl: null,
      bottomOverlayHeight: bottomOverlayHeight,
      viewportController: viewportController,
      onDebugListItemCountChanged: (_) => listBuildCount++,
    );
  }
}

Future<ProviderContainer> _pumpHost(
  WidgetTester tester,
  GlobalKey<_HostState> hostKey, {
  double width = 360,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 640);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final tempDir = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('stream_follow_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);
    ChatMessageListDisplayCache.clear();
    await ChatMessageListDisplayCache.clearPersistent();
    return dir;
  });
  addTearDown(() {
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider
            .overrideWith(() => _FakeAppSettingsNotifier(_buildSettings())),
        streamProjectionPolicyProvider.overrideWithValue(
          const StreamProjectionPolicy(useActiveStreamChannel: true),
        ),
      ],
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: 520,
                child: _Host(key: hostKey),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
  return ProviderScope.containerOf(
    tester.element(find.byType(ChatMessageList)),
  );
}

double _distanceToBottom(WidgetTester tester) {
  final controller = tester
      .widget<CustomScrollView>(find.byType(CustomScrollView))
      .controller!;
  final position = controller.position;
  return position.pixels - position.minScrollExtent;
}

String _growingText(int step) =>
    List.filled(step, '实时增长的流式正文第$step轮，足够长以改变气泡高度。').join('\n');

void _publishGrowth(ProviderContainer container, int step) {
  container.read(activeStreamProjectionsProvider.notifier).publish(
        ActiveStreamProjection(
          conversationId: _kConvId,
          generationSeq: 1,
          writeEpoch: step,
          tailMessageId: _kStreamShellId,
          tailText: _growingText(step),
          phase: ActiveStreamPhase.streamingTail,
        ),
      );
}

Future<void> _settleStabilization(WidgetTester tester) async {
  // 布局修正及帧后兜底收敛；额外推进 300ms，检测旧延迟补位是否复活。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 40));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in <double>[360, 1000]) {
    for (final scenario in [
      (copyTimeline: false, delayedRebuild: false),
      (copyTimeline: true, delayedRebuild: false),
      (copyTimeline: false, delayedRebuild: true),
      (copyTimeline: true, delayedRebuild: true),
    ]) {
      testWidgets('发送前切换尾部分区不应让已显示气泡跳动（${width}px，$scenario）', (tester) async {
        final hostKey = GlobalKey<_HostState>();
        await _pumpHost(tester, hostKey, width: width);
        final host = hostKey.currentState!;
        final completedTail = host.messages.last;
        host.setMessages([
          ...host.messages.take(host.messages.length - 1),
          Message.fromBlocks(
            id: completedTail.id,
            role: completedTail.role,
            blocks: completedTail.blocks!,
            createdAt: completedTail.createdAt,
            status: 'sent',
          ),
        ]);
        await tester.pumpAndSettle();
        final tail = find.byKey(
          const ValueKey<String>('message_bubble_$_kStreamShellId'),
        );
        final before = tester.getRect(tail);
        final rowBottom = tester
            .getRect(find.byKey(const ValueKey('message:$_kStreamShellId')))
            .bottom;

        // 正式发送先通知视口，再异步写入消息；期间页面可能因发送状态
        // 重建，但时间线仍是旧的。必须量已绘制气泡，不能只看帖后 pixels。
        host.viewportController.onUserSend();
        if (scenario.delayedRebuild) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        host.setMessages(scenario.copyTimeline
            ? List<Message>.of(host.messages)
            : host.messages);
        await tester.pump();
        final firstFrameTop = tester.getRect(tail).top;
        await tester.pump(const Duration(milliseconds: 16));
        final secondFrameTop = tester.getRect(tail).top;
        await tester.pumpAndSettle();
        expect(firstFrameTop, closeTo(before.top, 0.5),
            reason: '尚未追加消息，首帧不能挪动旧内容；'
                '发送前=${before.top}，首帧=$firstFrameTop，次帧=$secondFrameTop');
        expect(secondFrameTop, closeTo(before.top, 0.5));

        // 分区对齐后继续追加用户消息与 AI 尾壳；下一轮发送也不能失去跟随。
        for (var turn = 0; turn < 2; turn++) {
          host.viewportController.onUserSend();
          for (final role in ['user', 'assistant']) {
            final id = '${role}_send_$turn';
            host.setMessages([
              ...host.messages,
              Message.text(
                id: id,
                role: role,
                content: '$role 第 $turn 轮消息',
                createdAt: host.messages.last.createdAt
                    .add(const Duration(seconds: 1)),
                status: 'sent',
              ),
            ]);
            await tester.pumpAndSettle();
            expect(_distanceToBottom(tester), lessThanOrEqualTo(0.5));
            expect(
              // 气泡可短于 42px 头像；用含头像的整行检查底部对齐。
              tester.getRect(find.byKey(ValueKey('message:$id'))).bottom,
              closeTo(rowBottom, 0.5),
              reason: '第 $turn 轮 $role 消息应继续对齐输入框上沿',
            );
          }
        }
      });
    }
  }

  testWidgets('S1 贴底跟随：通道驱动气泡增高仍贴底，且列表不重建、实时文本上屏', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8), reason: '初始应贴底');
    // 种子 publish：生产中「壳首次出现」伴随结构性时间线写入、由
    // didUpdateWidget 稳底路径负责（S-04 分工）；窄信号只管后续同尾增长。
    // 台架无结构写，先建立 prev 再度量增长步。
    container.read(activeStreamProjectionsProvider.notifier).publish(
          const ActiveStreamProjection(
            conversationId: _kConvId,
            generationSeq: 1,
            writeEpoch: 0,
            tailMessageId: _kStreamShellId,
            tailText: '起',
            phase: ActiveStreamPhase.streamingTail,
          ),
        );
    await _settleStabilization(tester);
    final buildsBefore = hostKey.currentState!.listBuildCount;

    for (var step = 1; step <= 3; step++) {
      _publishGrowth(container, step);
      await _settleStabilization(tester);
      expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
          reason: '第$step轮增高后应保持贴底（窄信号稳底）');
    }
    expect(hostKey.currentState!.listBuildCount, buildsBefore,
        reason: '通道文本增长不得重建 ChatMessageList（Consumer 隔离）');
    expect(find.textContaining('实时增长的流式正文第3轮'), findsOneWidget,
        reason: '活跃气泡应渲染通道实时文本');
  });

  testWidgets('S1b 贴底跟随：增高生效的那一帧渲染树里尾气泡就已在视口内（无错帧）', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    container.read(activeStreamProjectionsProvider.notifier).publish(
          const ActiveStreamProjection(
            conversationId: _kConvId,
            generationSeq: 1,
            writeEpoch: 0,
            tailMessageId: _kStreamShellId,
            tailText: '起',
            phase: ActiveStreamPhase.streamingTail,
          ),
        );
    await _settleStabilization(tester);

    final viewportBottom =
        tester.getBottomLeft(find.byType(CustomScrollView)).dy;
    for (var step = 1; step <= 3; step++) {
      // 每轮增长 6 行，单轮增量必须明显超过列表 bottom padding（70px），
      // 否则尾气泡只是吃掉 padding 余量、本就不会出视口，测试失去区分力。
      _publishGrowth(container, step * 6);
      // 只 pump 一帧：帖后 jumpTo 此时只改了 offset，渲染树仍是这一帧的
      // 布局结果；若靶底靠帖后补位，尾气泡底边会落在视口之外（错帧）。
      await tester.pump();
      final bubble = find.byKey(
        const ValueKey<String>('message_bubble_$_kStreamShellId'),
      );
      expect(bubble, findsOneWidget);
      expect(tester.getBottomLeft(bubble).dy, lessThanOrEqualTo(viewportBottom),
          reason: '第$step轮增高的首帧渲染结果里尾气泡不得被推出视口底部');
    }
    // 继续推进时间，确保首帧之后也没有旧补位把画面拉走。
    await _settleStabilization(tester);
  });

  for (final width in <double>[360, 1000]) {
    testWidgets('S2a $width px：按下即让路，持续拖动时文字增长但画面只跟手', (tester) async {
      final hostKey = GlobalKey<_HostState>();
      final container = await _pumpHost(tester, hostKey, width: width);
      _publishGrowth(container, 1);
      await _settleStabilization(tester);
      final list = find.byType(CustomScrollView);
      expect(tester.getSize(list).width, width);
      final controller = tester.widget<CustomScrollView>(list).controller!;
      final anchor = find.byKey(
        const ValueKey<String>('message_bubble_$_kStreamShellId'),
      );
      final before = tester.getTopLeft(anchor).dy;
      final gesture = await tester.startGesture(tester.getCenter(list));
      // 尚未达到拖动阈值，生成也不得把手指下面的内容拉走。
      _publishGrowth(container, 2);
      await tester.pump();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.5));

      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      final builds = hostKey.currentState!.listBuildCount;
      for (var step = 3; step <= 8; step++) {
        final top = tester.getTopLeft(anchor).dy;
        final pixels = controller.position.pixels;
        _publishGrowth(container, step);
        await gesture.moveBy(const Offset(0, 8));
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.textContaining('实时增长的流式正文第$step轮', skipOffstage: false),
            findsOneWidget,
            reason: '不能通过冻结文字来伪装跟手');
        expect(controller.position.pixels - pixels, closeTo(8, 0.5));
        expect(tester.getTopLeft(anchor).dy - top, closeTo(8, 0.5),
            reason: '增长帧中画面位移只能来自手指');
      }
      expect(hostKey.currentState!.listBuildCount, builds,
          reason: '拖动与纯文本增长不得重建整个列表');
      await gesture.up();
      await _settleStabilization(tester);
      expect(hostKey.currentState!.viewportController.isDetached, isTrue);
      final stoppedTop = tester.getTopLeft(anchor).dy;
      _publishGrowth(container, 9);
      await _settleStabilization(tester);
      expect(tester.getTopLeft(anchor).dy, closeTo(stoppedTop, 0.5),
          reason: '松手后不自动恢复跟随');
    });

    testWidgets('S2c $width px：拖动期间分段换尾实时上屏且旧消息不跳', (tester) async {
      final hostKey = GlobalKey<_HostState>();
      final container = await _pumpHost(tester, hostKey, width: width);
      hostKey.currentState!.viewportController.onUserSend();
      _publishGrowth(container, 1);
      await _settleStabilization(tester);
      final user = find.byKey(const ValueKey<String>('message_bubble_m_13'));
      final originalElement = tester.element(user);
      final gesture = await tester
          .startGesture(tester.getCenter(find.byType(CustomScrollView)));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(identical(tester.element(user), originalElement), isTrue,
          reason: '从发送跟随转手势不能把用户消息挪到另一棵 sliver');
      final top = tester.getTopLeft(user).dy;
      final host = hostKey.currentState!;
      final shell = host.messages.last;
      host.setMessages([
        ...host.messages.take(host.messages.length - 1),
        Message.fromBlocks(
            id: shell.id,
            role: 'assistant',
            blocks: [TextBlock(messageId: shell.id, content: _growingText(1))],
            createdAt: shell.createdAt,
            status: 'sent'),
        Message.fromBlocks(
            id: 'next_shell',
            role: 'assistant',
            blocks: [TextBlock(messageId: 'next_shell', content: '新分段壳')],
            createdAt: shell.createdAt.add(const Duration(seconds: 1)),
            status: 'sending'),
      ]);
      container.read(activeStreamProjectionsProvider.notifier).publish(
          const ActiveStreamProjection(
              conversationId: _kConvId,
              generationSeq: 1,
              writeEpoch: 2,
              tailMessageId: 'next_shell',
              tailText: '新分段继续生成',
              phase: ActiveStreamPhase.streamingTail));
      await tester.pump();
      expect(
          find.textContaining('新分段继续生成', skipOffstage: false), findsOneWidget,
          reason: '换尾不能等松手才显示，否则下一段生成又被冻住');
      expect(tester.getTopLeft(user).dy, closeTo(top, 0.5));
      expect(identical(tester.element(user), originalElement), isTrue);
      await gesture.up();
      await _settleStabilization(tester);
      expect(host.viewportController.isDetached, isTrue);
    });

    testWidgets('S2b $width px：回底动画期间生成不停，再次按下立即取消旧跟随', (tester) async {
      final hostKey = GlobalKey<_HostState>();
      final container = await _pumpHost(tester, hostKey, width: width);
      _publishGrowth(container, 1);
      await _settleStabilization(tester);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 220));
      await _settleStabilization(tester);
      _publishGrowth(container, 3);
      await tester.pump();
      await tester
          .tap(find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(_distanceToBottom(tester), greaterThan(8), reason: '必须是动画回底，不是瞬移');
      _publishGrowth(container, 4);
      await tester.pump(const Duration(milliseconds: 16));
      final list = find.byType(CustomScrollView);
      final controller = tester.widget<CustomScrollView>(list).controller!;
      final gesture = await tester.startGesture(tester.getCenter(list));
      final pixels = controller.position.pixels;
      for (var step = 5; step <= 8; step++) {
        _publishGrowth(container, step);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.position.pixels, closeTo(pixels, 0.5),
            reason: '旧重试与增长不得取消手指按住产生的 hold');
      }
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.up();
      await _settleStabilization(tester);
      expect(hostKey.currentState!.viewportController.isDetached, isTrue);
      await tester
          .tap(find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')));
      for (var step = 9; step <= 20; step++) {
        _publishGrowth(container, step);
        await tester.pump(const Duration(milliseconds: 32));
      }
      await _settleStabilization(tester);
      expect(_distanceToBottom(tester), lessThanOrEqualTo(0.5));
      _publishGrowth(container, 21);
      await tester.pump();
      final anchor =
          find.byKey(const ValueKey<String>('message_bubble_$_kStreamShellId'));
      expect(tester.getBottomLeft(anchor).dy,
          lessThanOrEqualTo(tester.getBottomLeft(list).dy),
          reason: '回底后恢复同帧自然增长');
      await _settleStabilization(tester);
    });
  }

  testWidgets('S2 detached 阅读：通道增高不移动锚点、不强制回底', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final gapDetached = _distanceToBottom(tester);
    expect(gapDetached, greaterThan(40), reason: '前置：已脱离贴底');

    // 阅读锚点＝可见历史气泡的屏幕位置（reverse 列表中距底偏移会随尾部
    // 长高等量增大以保持画面稳定，偏移差不是正确契约）。
    String? anchorText;
    double? anchorDy;
    for (var i = 13; i >= 0; i--) {
      final candidate = find.textContaining('历史消息内容第$i条');
      if (candidate.evaluate().isNotEmpty) {
        anchorText = '历史消息内容第$i条';
        anchorDy = tester.getTopLeft(candidate.first).dy;
        break;
      }
    }
    expect(anchorText, isNotNull, reason: '前置：应有可见历史气泡作锚点');

    for (var step = 1; step <= 3; step++) {
      _publishGrowth(container, step);
      await _settleStabilization(tester);
    }
    expect(_distanceToBottom(tester), greaterThan(40),
        reason: 'detached 下通道增高不得强制回底');
    final anchorAfter = find.textContaining(anchorText!);
    expect(anchorAfter.evaluate().isNotEmpty, isTrue, reason: '锚点历史气泡应仍在屏上');
    expect((tester.getTopLeft(anchorAfter.first).dy - anchorDy!).abs(),
        lessThanOrEqualTo(2),
        reason: 'detached 阅读画面（历史气泡屏幕位置）不得被通道增高移动');
  });

  testWidgets('S2f 多指按住时增长不拉动，最后一指释放且未拖动才恢复跟随', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    _publishGrowth(container, 1);
    await _settleStabilization(tester);
    final list = find.byType(CustomScrollView);
    final position = tester.widget<CustomScrollView>(list).controller!.position;
    final first = await tester.startGesture(tester.getCenter(list), pointer: 1);
    final second = await tester
        .startGesture(tester.getCenter(list) + const Offset(40, 0), pointer: 2);
    final before = position.pixels;
    _publishGrowth(container, 6);
    await tester.pump();
    await first.up();
    await _settleStabilization(tester);
    expect(position.pixels, closeTo(before, 0.5));
    await second.cancel();
    await _settleStabilization(tester);
    expect(hostKey.currentState!.viewportController.shouldFollowLatest, isTrue);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(0.5));
  });

  testWidgets('S2g 回底动画中滚轮立即接管，不被动画完成回调拉走', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey, width: 1000);
    _publishGrowth(container, 1);
    await _settleStabilization(tester);
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, 250));
    await _settleStabilization(tester);
    await tester
        .tap(find.byKey(const ValueKey<String>('chat_jump_to_latest_badge')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    await tester.sendEventToBinding(PointerScrollEvent(
        position: tester.getCenter(list), scrollDelta: const Offset(0, -80)));
    await tester.pump();
    expect(hostKey.currentState!.viewportController.isDetached, isTrue);
    final position = tester.widget<CustomScrollView>(list).controller!.position;
    final before = position.pixels;
    _publishGrowth(container, 3);
    await _settleStabilization(tester);
    expect(position.pixels, closeTo(before, 0.5));
  });

  testWidgets('S2d 流式增高不能截断或改变松手后的惯性轨迹', (tester) async {
    Future<List<double>> trajectory({required bool grow}) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final hostKey = GlobalKey<_HostState>();
      final container = await _pumpHost(tester, hostKey);
      _publishGrowth(container, 1);
      await _settleStabilization(tester);
      final list = find.byType(CustomScrollView);
      await tester.fling(list, const Offset(0, 100), 500);
      final position =
          tester.widget<CustomScrollView>(list).controller!.position;
      final start = position.pixels;
      expect(position.isScrollingNotifier.value, isTrue);
      final samples = <double>[];
      for (var frame = 0; frame < 10; frame++) {
        if (grow) _publishGrowth(container, frame + 2);
        await tester.pump(const Duration(milliseconds: 16));
        samples.add(position.pixels - start);
        expect(position.isScrollingNotifier.value, isTrue,
            reason: '流式布局不能 jumpTo 截断惯性');
      }
      await tester.pump(const Duration(seconds: 2));
      await _settleStabilization(tester);
      return samples;
    }

    final baseline = await trajectory(grow: false);
    final streaming = await trajectory(grow: true);
    for (var frame = 0; frame < baseline.length; frame++) {
      expect(streaming[frame], closeTo(baseline[frame], 0.5),
          reason: '第$frame帧：相同手势的惯性不能被生成改变');
    }
  });

  testWidgets('S2e 阅读中图片尺寸改变不能在帧后搬动画面', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    await _pumpHost(tester, hostKey);
    final host = hostKey.currentState!;
    Message photo(int height) => Message.fromBlocks(
        id: _kStreamShellId,
        role: 'assistant',
        blocks: [
          ImageBlock(
              messageId: _kStreamShellId, url: '', width: 400, height: height)
        ],
        createdAt: host.messages.last.createdAt,
        status: 'sent');
    host.setMessages([...host.messages.take(14), photo(100)]);
    await _settleStabilization(tester);
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(CustomScrollView)));
    await gesture.moveBy(const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await _settleStabilization(tester);
    final anchor = find.byKey(const ValueKey<String>('message_bubble_m_13'));
    final before = tester.getTopLeft(anchor).dy;
    host.setMessages([...host.messages.take(14), photo(600)]);
    await _settleStabilization(tester);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.5),
        reason: '固定 center 的活跃区向下长高，不需要按 minExtent 做像素补偿');
  });

  testWidgets('S3 历史分页加载中：通道增高不得触发回底争抢', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    final gapDetached = _distanceToBottom(tester);
    expect(gapDetached, greaterThan(40));

    // isLoadingMore 语义经 widget 层进入分页保持路径；此处直接以 detached
    // ＋连续增高验证「加载窗口期不回底」的外观契约。
    for (var step = 1; step <= 2; step++) {
      _publishGrowth(container, step);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), greaterThan(40),
        reason: '分页/脱离窗口期通道增高不得抢占视口回底');
  });

  testWidgets('S5 键盘/底部遮挡同帧变化：贴底不破、不遮输入区', (tester) async {
    final hostKey = GlobalKey<_HostState>();
    final container = await _pumpHost(tester, hostKey);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8));

    // 同帧：底部 overlay 升高（键盘/面板）＋通道文本增长。
    hostKey.currentState!.setOverlay(160);
    _publishGrowth(container, 1);
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
        reason: 'overlay 变化与通道增高同帧后仍应贴底（最后消息不被遮）');

    hostKey.currentState!.setOverlay(0);
    _publishGrowth(container, 2);
    await _settleStabilization(tester);
    expect(_distanceToBottom(tester), lessThanOrEqualTo(8),
        reason: 'overlay 收起后继续增高仍贴底');
  });
}
