import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/ui/shared/widgets/moe_floating_surface.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_selection.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_viewport_controller.dart';
import 'package:aicove_flutter/src/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

Message message(int index, {String? status}) => Message(
  id: '$index',
  role: 'assistant',
  content: 'Message $index',
  createdAt: DateTime(2026, 9, 12).add(Duration(minutes: index)),
  status: status,
);

void main() {
  test('连续选择、反向缩短、取消选择以及插入历史都按稳定 ID 工作', () {
    final selection = ChatMessageSelection();
    addTearDown(selection.dispose);
    selection.updateMessages(List.generate(8, message));
    selection.start('7');
    selection.beginDrag('5');
    selection.extendDrag('2');
    expect(selection.selectedMessages.map((m) => m.id), [
      '2',
      '3',
      '4',
      '5',
      '7',
    ]);
    selection.extendDrag('4');
    expect(selection.selectedMessages.map((m) => m.id), ['4', '5', '7']);
    selection.endDrag();
    selection.beginDrag('5');
    selection.extendDrag('7');
    expect(selection.selectedMessages.map((m) => m.id), ['4']);
    selection.endDrag();
    selection.beginDrag('1');
    selection.updateMessages(List.generate(10, (i) => message(i - 2)));
    selection.extendDrag('-2');
    expect(selection.selectedMessages.map((m) => m.id), [
      '-2',
      '-1',
      '0',
      '1',
      '4',
    ]);
  });

  test('发送中不可选、删除不残留，分段按单个气泡导出', () {
    final selection = ChatMessageSelection();
    addTearDown(selection.dispose);
    final chunk = chatListItemSelectionMessage(
      ChatChunkedMessageItem(
        originalMessage: message(0),
        chunkText: '只导出这一段',
        chunkIndex: 1,
        totalChunks: 3,
      ),
    )!;
    selection.updateMessages([chunk, message(1, status: 'sending')]);
    selection.start('1');
    expect(selection.active, isFalse);
    selection.start(chunk.id);
    expect(selection.selectedMessages.single.content, '只导出这一段');
    expect(selection.updateMessages([]), isTrue);
    expect(selection.count, 0);
    selection.clear();
    expect(selection.active, isFalse);
  });

  test('没有可见气泡的内部记录不产生选择项', () {
    final hidden = Message(
      id: 'internal',
      role: 'assistant',
      content: '',
      blocks: [TextBlock(id: 'empty', messageId: 'internal', content: '   ')],
      createdAt: DateTime(2026),
    );
    expect(chatListItemSelectionMessage(ChatMessageItem(hidden)), isNull);
  });

  testWidgets('图文按显示气泡生成选择按钮，空白记录不生成按钮', (tester) async {
    final fixture = (await tester.runAsync(
      () => SegmentedChatFixture.create(historyCount: 0),
    ))!;
    final raw = Message(
      id: 'mixed',
      role: 'user',
      content: '',
      createdAt: DateTime(2026),
      blocks: [
        TextBlock(messageId: 'mixed', content: '图片说明'),
        ImageBlock(messageId: 'mixed', url: '', width: 80, height: 80),
        ImageBlock(messageId: 'mixed', url: '', width: 80, height: 80),
      ],
    );
    final projected = const ChatFrontendMessageProjectionService()
        .projectMessage(raw);
    final hidden = Message(
      id: 'hidden',
      role: 'assistant',
      content: '',
      createdAt: DateTime(2026),
      blocks: [TextBlock(messageId: 'hidden', content: '')],
    );
    final selection = ChatMessageSelection()..enter();
    final viewport = ChatViewportController();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: ThemeData(extensions: [MoeColors.light()]),
          home: Scaffold(
            body: ChatMessageList(
              conversationId: fixture.conversation.id,
              messages: [...projected, hidden],
              displayName: '气泡数量测试',
              viewportController: viewport,
              selection: selection,
              hasMoreMessages: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(projected, hasLength(3));
    for (final message in projected) {
      expect(
        find.byKey(ValueKey('message-select-${message.id}')),
        findsOneWidget,
      );
    }
    expect(find.byKey(const ValueKey('message-select-hidden')), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith(
              'message-select-',
            ),
      ),
      findsNWidgets(3),
    );
    await tester.tap(find.byKey(ValueKey('message-select-${projected[1].id}')));
    await tester.pumpAndSettle();
    expect(selection.selectedMessages.single.id, projected[1].id);
    expect(selection.selectedMessages.single.blocks!.single, isA<ImageBlock>());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    selection.dispose();
    viewport.dispose();
    await tester.runAsync(fixture.dispose);
  });

  for (final width in [360.0, 700.0]) {
    testWidgets('长按、多选、滑动连选、边缘自动滚动与普通翻阅 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      final fixture = (await tester.runAsync(
        () => SegmentedChatFixture.create(historyCount: 60),
      ))!;
      final selection = ChatMessageSelection();
      final viewport = ChatViewportController();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            theme: ThemeData(extensions: [MoeColors.light()]),
            home: Scaffold(
              body: ChatMessageList(
                conversationId: fixture.conversation.id,
                messages: fixture.conversation.messages,
                displayName: '滑动多选测试',
                selection: selection,
                viewportController: viewport,
                hasMoreMessages: false,
                topOverlayHeight: 16,
                bottomOverlayHeight: 24,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalRects = {
        for (final id in ['probe_history_58', 'probe_history_59'])
          id: tester.getRect(find.byKey(ValueKey('message_bubble_$id'))),
      };
      final pressPosition =
          tester
              .getRect(
                find.byKey(const ValueKey('message_bubble_probe_history_59')),
              )
              .bottomLeft +
          const Offset(24, -8);
      await tester.longPressAt(pressPosition);
      await tester.pumpAndSettle();
      expect(find.text('多选'), findsOneWidget);
      final menuRect = tester.getRect(
        find.ancestor(
          of: find.text('多选'),
          matching: find.byType(MoeFloatingSurface),
        ),
      );
      expect(
        (menuRect.top - pressPosition.dy).abs() < 0.01 ||
            (menuRect.bottom - pressPosition.dy).abs() < 0.01,
        isTrue,
        reason: '菜单贴着实际长按位置展开，而不是整条消息边缘',
      );
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(selection.selectedMessages.single.id, 'probe_history_59');

      for (final id in ['probe_history_58', 'probe_history_59']) {
        final control = tester.getRect(
          find.byKey(ValueKey('message-select-$id')),
        );
        final bubble = tester.getRect(
          find.byKey(ValueKey('message_bubble_$id')),
        );
        expect(bubble, originalRects[id], reason: '进入多选不改变消息位置或尺寸');
        expect(control.width, 42);
        expect(control.right, lessThanOrEqualTo(bubble.left - 8));
      }
      final start = tester.getCenter(
        find.byKey(const ValueKey('message-select-probe_history_58')),
      );
      final target = tester.getCenter(
        find.byKey(const ValueKey('message-select-probe_history_56')),
      );
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(0, -24));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      expect(selection.selectedMessages.map((m) => m.id), [
        'probe_history_56',
        'probe_history_57',
        'probe_history_58',
        'probe_history_59',
      ]);
      await gesture.moveTo(Offset(start.dx, 20));
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selection.count, greaterThan(20), reason: '边缘停留会滚动并选到屏幕外消息');
      final selected = selection.selectedMessages.map((m) => m.id).toList();
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      final before = scroll.pixels;
      await tester.dragFrom(Offset(width * .7, 350), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(scroll.pixels, isNot(before));
      expect(
        selection.selectedMessages.map((m) => m.id),
        selected,
        reason: '消息区普通滑动只翻阅，不改变选择',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
      viewport.dispose();
      await tester.runAsync(fixture.dispose);
    });
  }
}
