import 'dart:io';
import 'dart:ui' as ui;

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/task_agent/application/delegate_task_plugin.dart';
import 'package:aicove_flutter/src/features/task_agent/domain/agent_task.dart';
import 'package:aicove_flutter/src/features/task_agent/task_agent_providers.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:aicove_flutter/src/ui/features/task_agent/task_running_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Source-rendered preview: `--dart-define=WRITE_TASK_PREVIEW=true`.
const _capture = bool.fromEnvironment('WRITE_TASK_PREVIEW');

AgentTask _task(AgentTaskStatus status) => AgentTask(
  id: 'task_1',
  requestKey: null,
  conversationId: 'c1',
  source: AgentTaskSource.chat,
  instruction: '查一下天气',
  status: status,
  frozen: false,
  notify: TaskReceiptNotify.always,
  receiptSeq: 0,
  questionReceiptId: null,
  pendingReceipt: null,
  sideEffectUncertain: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

ToolBlock _delegateBlock(Object? result) => ToolBlock(
  id: 'tool_1',
  messageId: 'm1',
  toolName: delegateTaskToolName,
  result: result is Map<String, dynamic> ? result : {'content': result},
);

Future<void> _pump(WidgetTester tester, AgentTaskStatus status) async {
  tester.view.physicalSize = const Size(360, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentTaskByIdProvider.overrideWith((ref, taskId) async => _task(status)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: TaskRunningBar(taskId: 'task_1', textColor: Colors.black),
          ),
        ),
      ),
    ),
  );
  // The spinner never settles, so pump a frame instead of waiting for it.
  await tester.pump();
  await tester.pump();
}

void main() {
  group('delegateTaskIdOf', () {
    test('reads task_id from a JSON string result', () {
      expect(
        delegateTaskIdOf(_delegateBlock('{"task_id":"task_1","status":"accepted"}')),
        'task_1',
      );
    });

    test('reads task_id from a map result', () {
      expect(
        delegateTaskIdOf(_delegateBlock({'task_id': 'task_2'})),
        'task_2',
      );
    });

    test('ignores other tools, errors and bad JSON', () {
      final other = ToolBlock(
        id: 'tool_2',
        messageId: 'm1',
        toolName: 'web_search',
        result: {'content': '{"task_id":"x"}'},
      );
      expect(delegateTaskIdOf(other), isNull);
      expect(delegateTaskIdOf(_delegateBlock('{"error":"只能在聊天里派活"}')), isNull);
      expect(delegateTaskIdOf(_delegateBlock('not json')), isNull);
    });
  });

  group('chat list', () {
    final at = DateTime(2026, 10, 21, 15, 37);
    const config = MessageFormatConfig(enableChunking: false);
    Message assistant(String id, String text, List<MessageBlock> blocks) =>
        Message(
          id: id,
          role: 'assistant',
          content: text,
          blocks: blocks,
          createdAt: at,
        );
    final receipt = Message(
      id: 'task_receipt_r1',
      role: 'user',
      content: '[杂活回执]',
      blocks: [
        TaskReceiptBlock(
          messageId: 'task_receipt_r1',
          receiptId: 'r1',
          taskId: 'task_1',
          receiptStatus: TaskReceiptStatus.done,
          summary: '做不到',
          executorDevice: 'phone',
        ),
      ],
      createdAt: at,
    );

    test('a delegate-only turn leaves just the waiting line, no bubble', () {
      final items = buildChatMessageListItems(
        messages: [
          assistant('a1', '', [_delegateBlock('{"task_id":"task_1"}')]),
          receipt,
          assistant('a2', '它说做不到。', const []),
        ],
        config: config,
        showTimeDividers: false,
      );
      expect(items, hasLength(2));
      expect((items[0] as ChatTaskRunningItem).taskId, 'task_1');
      final reply = items[1] as ChatMessageItem;
      expect(reply.message.id, 'a2');
      expect(reply.showAvatar, isTrue);
    });

    test('text with a delegate call keeps the bubble, line follows it', () {
      final items = buildChatMessageListItems(
        messages: [
          assistant('a1', '我去问问。', [
            TextBlock(messageId: 'a1', content: '我去问问。'),
            _delegateBlock('{"task_id":"task_1"}'),
          ]),
        ],
        config: config,
        showTimeDividers: false,
      );
      expect(items.map((item) => item.runtimeType), [
        ChatMessageItem,
        ChatTaskRunningItem,
      ]);
    });
  });

  testWidgets('shows the bar while the task is queued or running', (tester) async {
    await _pump(tester, AgentTaskStatus.running);
    expect(find.textContaining('处理中'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-running-task_1')), findsOneWidget);
  });

  testWidgets('shows queued wording before the helper starts', (tester) async {
    await _pump(tester, AgentTaskStatus.queued);
    expect(find.textContaining('排队中'), findsOneWidget);
  });

  testWidgets('hides the bar once the task has settled', (tester) async {
    await _pump(tester, AgentTaskStatus.done);
    expect(find.byKey(const ValueKey('task-running-task_1')), findsNothing);
  });

  testWidgets('renders the running state for the preview', (tester) async {
    tester.view.physicalSize = const Size(360, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    if (_capture) {
      // Load the CJK font before the first frame, or the text draws as boxes.
      await tester.runAsync(() async {
        final text = FontLoader('Preview')
          ..addFont(
            File('/System/Library/Fonts/STHeiti Medium.ttc')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await text.load();
      });
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentTaskByIdProvider.overrideWith(
            (ref, taskId) async => _task(AgentTaskStatus.running),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(fontFamily: _capture ? 'Preview' : null),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('我去查一下，好了告诉你。'),
                    TaskRunningBar(taskId: 'task_1', textColor: Colors.black87),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The spinner never settles, so pump a frame instead of waiting for it.
  await tester.pump();
  // Let the spinner turn a little, so the preview shows the arc, not a dot.
  await tester.pump(const Duration(milliseconds: 600));
    if (!_capture) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = Directory('../../.codex-temp/task_agent/previews')
        ..createSync(recursive: true);
      await File('${out.path}/task_running_bar.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
