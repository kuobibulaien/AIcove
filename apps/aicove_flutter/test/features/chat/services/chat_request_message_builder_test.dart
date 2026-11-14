import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../ui/features/chat/pages/chat_interface_test_support.dart';

void main() {
  test('receipt detail expands once and then folds', () async {
    final block = TaskReceiptBlock(
      messageId: 'r',
      receiptId: 'r1',
      taskId: 't',
      receiptStatus: TaskReceiptStatus.done,
      summary: '摘要',
      detail: '素材原文',
      executorDevice: 'mac',
    );
    final receipt = Message(
      id: 'r',
      role: 'user',
      content: block.content,
      blocks: [block],
      createdAt: DateTime.now(),
    );
    final reply = Message.text(id: 'a', role: 'assistant', content: '回答');
    final builder = ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    );
    final first = await builder.buildRequestMessages([
      receipt,
    ], settings: chatInterfaceTestSettings());
    expect(first.toString(), contains('素材原文'));
    final next = await builder.buildRequestMessages([
      receipt,
      reply,
    ], settings: chatInterfaceTestSettings());
    expect(next.toString(), isNot(contains('素材原文')));
    expect(TaskReceiptBlock.fromJson(block.toJson()).detail, '素材原文');
  });

  test('historical delegate tool result drops detail', () async {
    final tool = ToolBlock(
      messageId: 'a',
      toolName: 'delegate_task',
      toolCallId: 'call',
      result: {
        'task_id': 't',
        'receipt_id': 'r',
        'status': 'done',
        'summary': '摘要',
        'detail': '素材原文',
      },
    );
    final reply = Message(
      id: 'a',
      role: 'assistant',
      content: '回答',
      blocks: [
        TextBlock(messageId: 'a', content: '回答'),
        tool,
      ],
      createdAt: DateTime.now(),
    );
    final result = await ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    ).buildRequestMessages([reply], settings: chatInterfaceTestSettings());
    expect(result.toString(), isNot(contains('素材原文')));
    expect(result.toString(), contains('摘要'));
  });
}
