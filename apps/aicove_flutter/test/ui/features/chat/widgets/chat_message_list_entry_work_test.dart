import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_display_cache.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/skin_provider.dart';
import 'package:aicove_flutter/src/ui/theme/skins/moetalk_skin.dart';

import '../../../../../tool/chat_segmented_fixture.dart';

List<Message> _history(bool projected) {
  final now = DateTime(2026, 1, 1);
  String text(int i) => '这是回复的第$i段内容用于验证初次进入只布局可见气泡。';
  return [
    Message.text(id: 'user', role: 'user', content: '问题', createdAt: now),
    if (projected)
      for (var i = 0; i < 120; i++)
        Message.text(
                id: 'p_$i',
                role: 'assistant',
                content: text(i),
                status: 'sent',
                createdAt: now.add(const Duration(minutes: 1)))
            .copyWith(sourceMessageId: 'assistant')
    else
      Message.text(
          id: 'assistant',
          role: 'assistant',
          status: 'sent',
          content: List.generate(120, text).join(),
          createdAt: now.add(const Duration(minutes: 1))),
  ];
}

Widget _host(SegmentedChatFixture fixture, ChatViewportController viewport,
        List<Message> messages, List<String> built,
        {String? contextStart}) =>
    UncontrolledProviderScope(
      container: fixture.container,
      child: SkinScope(
          skin: const MoeTalkSkin(),
          child: MaterialApp(
            home: Scaffold(
                body: ChatMessageList(
              conversationId: fixture.conversation.id,
              messages: messages,
              displayName: '测试',
              viewportController: viewport,
              contextStartMessageId: contextStart,
              hasMoreMessages: false,
              onDebugItemBuilt: built.add,
            )),
          )),
    );

Finder _bubble(String id) =>
    find.byWidgetPredicate((w) => w is MessageBubble && w.message.id == id,
        skipOffstage: false);

void main() {
  for (final width in [360.0, 1000.0]) {
    for (final projected in [false, true]) {
      for (final compact in [false, true]) {
        testWidgets(
            '长回复首屏构建有界、拖动后追加不跳、回底正常：$width projected=$projected compact=$compact',
            (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture =
              (await tester.runAsync(() => SegmentedChatFixture.create(
                    historyCount: 0,
                    settings: segmentedProbeSettings.copyWith(
                        messageFormatConfig: MessageFormatConfig(
                            minSegmentLength: compact ? 60 : 5)),
                  )))!;
          final viewport = ChatViewportController();
          final built = <String>[];
          ChatMessageListDisplayCache.clear();
          var messages = _history(projected);
          await tester.pumpWidget(_host(fixture, viewport, messages, built));
          final firstFrameBuilds = built.length;
          final tail = find.byWidgetPredicate(
              (w) =>
                  w is MessageBubble && w.message.displayText.contains('第119段'),
              skipOffstage: false);
          expect(tail, findsOneWidget);
          expect(tester.getBottomLeft(tail).dy, inInclusiveRange(700.0, 735.0));
          expect(firstFrameBuilds, lessThan(40),
              reason: '不能从组头逐个排版到组尾，实际构建 $firstFrameBuilds 个列表项');
          debugPrint(
              '[ChatEntryWork] width=$width projected=$projected compact=$compact firstFrameBuilds=$firstFrameBuilds');
          await tester.pumpAndSettle();

          final scroll = find.byType(CustomScrollView);
          final gesture = await tester.startGesture(tester.getCenter(scroll));
          await gesture.moveBy(const Offset(0, 240));
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 120));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(viewport.isDetached, isTrue);
          final anchor = tester
              .widgetList<MessageBubble>(find.byType(MessageBubble))
              .firstWhere((bubble) {
            final rect = tester.getRect(_bubble(bubble.message.id));
            return rect.top > 150 && rect.bottom < 650;
          });
          final before = tester.getTopLeft(_bubble(anchor.message.id)).dy;
          messages = [
            ...messages,
            Message.text(
                id: 'new',
                role: 'assistant',
                content: '新的回复',
                status: 'sent',
                createdAt: DateTime(2026, 1, 1, 0, 2))
          ];
          await tester.pumpWidget(_host(fixture, viewport, messages, built));
          expect(tester.getTopLeft(_bubble(anchor.message.id)).dy,
              closeTo(before, .5),
              reason: '入场分界不能在追加消息/手势后变回整组分界');
          viewport.onJumpToLatest();
          await tester.pumpAndSettle();
          final controller =
              tester.widget<CustomScrollView>(scroll).controller!;
          expect(
              controller.position.pixels - controller.position.minScrollExtent,
              closeTo(0, .5));
          expect(tester.getBottomLeft(_bubble('new')).dy,
              inInclusiveRange(700.0, 735.0));

          // 删掉原入场锚点后必须恢复有效分区，不能保留悬空 key。
          messages = [messages.first, messages.last];
          await tester.pumpWidget(_host(fixture, viewport, messages, built));
          viewport.onJumpToLatest();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(_bubble('new'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          viewport.dispose();
          await tester.runAsync(fixture.dispose);
        });
      }
    }
  }

  testWidgets('长消息分段跨入场分界时，新话题线只能出现在整条消息之后一次', (tester) async {
    final fixture = (await tester
        .runAsync(() => SegmentedChatFixture.create(historyCount: 0)))!;
    final viewport = ChatViewportController();
    final built = <String>[];
    await tester.pumpWidget(_host(fixture, viewport, _history(false), built,
        contextStart: 'assistant'));
    final count = find
        .byKey(const ValueKey('topic:assistant'), skipOffstage: false)
        .evaluate()
        .length;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    viewport.dispose();
    await tester.runAsync(fixture.dispose);
    expect(count, 1);
  });
}
