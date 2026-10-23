import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Future<void> _settle(WidgetTester tester) async {
  // 生成占位符一直动画，不使用 pumpAndSettle。
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Widget _host(
  SegmentedChatFixture fixture,
  ChatViewportController viewport,
  ValueListenable<List<Message>> timeline,
) =>
    UncontrolledProviderScope(
      container: fixture.container,
      child: SkinScope(
        skin: const MoeTalkSkin(),
        child: MaterialApp(
            home: Scaffold(
                body: ValueListenableBuilder<List<Message>>(
          valueListenable: timeline,
          builder: (context, messages, _) => ChatMessageList(
            conversationId: fixture.conversation.id,
            messages: messages,
            displayName: '真实分段测试',
            viewportController: viewport,
            hasMoreMessages: false,
            chatDisplayStyle: ChatDisplayStyle.document,
          ),
        ))),
      ),
    );

const _round1 = '我先去看看仓库结构和运行要求。';
const _round2 = '工作区里同时只能运行一条命令，我改成串行执行。';
final _answer = [
  for (var i = 0; i < 6; i++)
    '## 小节$i\n\n这是第$i段正文，**加粗**内容和`代码`，足够长以换行展示文档模式的 Markdown 渲染效果。\n',
].join('\n');

/// 两轮各调三次工具后给出正文，与内核 runner 交付的逐轮结构一致。
ApiCallResult _toolRounds(String streamed) {
  final calls = [
    for (var i = 0; i < 6; i++)
      ToolCall(id: 'call_$i', name: 'bash', arguments: {'command': 'ls $i'}),
  ];
  return ApiCallResult(
    replyText: streamed,
    processedText: streamed,
    pluginEvents: const [],
    toolResults: const [],
    toolCalls: calls,
    rawToolResults: [
      for (final call in calls)
        ToolResult(toolCallId: call.id, name: call.name, result: 'ok'),
    ],
    replyRounds: [
      const ReplyRound(
        replyText: _round1,
        processedText: _round1,
        toolCallIds: ['call_0', 'call_1', 'call_2'],
      ),
      const ReplyRound(
        replyText: _round2,
        processedText: _round2,
        toolCallIds: ['call_3', 'call_4', 'call_5'],
      ),
      ReplyRound(replyText: _answer, processedText: _answer),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory directory;
  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('tool_finalize_scroll_');
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    PathProviderPlatform.instance = originalPaths;
    directory.deleteSync(recursive: true);
  });

  // AIcove酱默认文档模式。调过工具的回复结束时按轮重建消息，比流式正文
  // 短，活跃区一次变矮几百像素：跟随时曾被推到活跃区与历史区接缝，
  // 生成中碰过触控板（已脱离跟随但仍在底部）时会越过底边再弹回。
  for (final touched in [false, true]) {
    testWidgets(
        touched
            ? '生成中碰过触控板仍在底部：带工具的回复结束时不回弹'
            : '贴底跟随：带工具的回复结束时不回弹、不跳走', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() => SegmentedChatFixture.create(
            historyCount: 20,
            finalResult: _toolRounds,
            decorate: (c) =>
                c.copyWith(chatDisplayStyle: ChatDisplayStyle.document),
          )))!;
      // 夹具的历史只进缓存；写进库里，发送后窗口重载时历史区才在。
      await tester.runAsync(() async {
        final store = fixture.container.read(chatHistoryStoreProvider);
        for (final message in fixture.timeline.value) {
          await store.appendMessage(
            conversationId: fixture.conversation.id,
            message: message,
          );
        }
      });
      // 时间线的每次写入排队，逐个上屏，收尾的中间态不会被合并掉。
      final display = ValueNotifier<List<Message>>(fixture.timeline.value);
      final pending = <List<Message>>[];
      void enqueue() => pending.add(fixture.timeline.value);
      fixture.timeline.addListener(enqueue);
      Future<void> drain() async {
        while (pending.isNotEmpty) {
          display.value = pending.removeAt(0);
          await tester.pump();
        }
      }

      final viewport = ChatViewportController();
      await tester.pumpWidget(_host(fixture, viewport, display));
      await _settle(tester);
      await tester.runAsync(fixture.start);
      addTearDown(() async {
        fixture.timeline.removeListener(enqueue);
        await fixture.dispose();
        viewport.dispose();
        display.dispose();
      });
      viewport.onUserSend();
      await drain();
      await _settle(tester);
      final list = find.byType(CustomScrollView);
      final scroll = tester.widget<CustomScrollView>(list).controller!;
      for (final text in [_round1, _round2, _answer, _answer]) {
        fixture.add(text);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)));
        await drain();
        await _settle(tester);
      }
      expect(display.value.length, greaterThan(20),
          reason: '历史消息仍在时间线里，收尾时历史区有内容');
      if (touched) {
        final gesture = await tester.startGesture(tester.getCenter(list));
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump();
        await gesture.up();
        await _settle(tester);
        expect(viewport.isDetached, isTrue);
      }
      await drain();
      expect(scroll.position.pixels - scroll.position.minScrollExtent,
          closeTo(0, 0.5));

      pending.clear();
      await tester.runAsync(fixture.finish);
      expect(pending, isNotEmpty);
      var frame = 0;
      void expectAtBottom(String when) {
        final position = scroll.position;
        expect(position.pixels - position.minScrollExtent, closeTo(0, 0.5),
            reason: '$when：内容变矮不能越过底边或被推走');
        expect(position.activity, isNot(isA<BallisticScrollActivity>()),
            reason: '$when：不能出现回弹动画');
      }

      while (pending.isNotEmpty) {
        display.value = pending.removeAt(0);
        await tester.pump();
        expectAtBottom('收尾第 ${++frame} 次写入');
      }
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expectAtBottom('收尾后第 $i 帧');
      }
      expect(display.value.any((m) => m.displayText == '生成中...'), isFalse);
      expect(
          display.value.any((m) =>
              m.blocks?.any((block) => block is ToolBlock) ?? false),
          isTrue,
          reason: '收尾后应出现工具调用消息');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
