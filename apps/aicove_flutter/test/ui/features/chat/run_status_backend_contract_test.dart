import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chat list reads what the send pipeline writes: the run status on the
/// turn's last assistant message and the codemode nested calls on its tool
/// block. Both sides go through their real functions here.
void main() {
  const call = ToolCall(
    id: 'call_cm',
    name: 'codemode',
    arguments: {'code': 'return await tools.bash({ command: "ls" });'},
  );
  const result = ToolResult(
    toolCallId: 'call_cm',
    name: 'codemode',
    result: 'Script completed\nWall time 0.3 seconds\nOutput:\nindex.html',
    structured: {
      'codemodeCalls': [
        {
          'id': 'call_cm/1',
          'name': 'bash',
          'args': '{"command":"ls"}',
          'status': 'ok',
          'durationMs': 300,
        },
      ],
    },
  );

  for (final status in ApiRunStatus.values) {
    test('pipeline status $status reaches the chat list', () {
      final apiResult = ApiCallResult(
        status: status,
        stopReason: status == ApiRunStatus.truncated ? 'length' : null,
        replyText: '我先看看这个项目',
        processedText: '我先看看这个项目',
        pluginEvents: const [],
        toolResults: const [],
        toolCalls: const [call],
        rawToolResults: const [result],
      );
      final built = const ChatMessageProcessor().buildAssistantMessages(
        replyText: apiResult.replyText,
        processedText: apiResult.processedText,
        pluginEvents: const [],
        toolCalls: apiResult.toolCalls,
        rawToolResults: apiResult.rawToolResults,
      ).messages;
      final messages = ChatMessageProjectionCodec.applyRunStatus(
        built,
        ChatMessageProjectionCodec.buildRawAssistantPayload(
          apiResult: apiResult,
        ),
      );

      final items = buildChatMessageListItems(
        messages: messages,
        config: const MessageFormatConfig(enableChunking: false),
        showToolCallFolds: true,
      );

      final statusItems = items.whereType<ChatRunStatusItem>().toList();
      if (status == ApiRunStatus.completed) {
        expect(statusItems, isEmpty);
      } else {
        expect(statusItems.single.status.name, status.name);
        expect(items.last, same(statusItems.single));
      }
      final fold = items
          .whereType<ChatChunkedMessageItem>()
          .map((item) => item.fold)
          .firstWhere((fold) => fold?.title == 'bash · ls')!;
      expect(fold.content, contains('```js'));
      expect(fold.content, contains('- `bash ls` 完成 · 300 毫秒'));
      expect(fold.content, contains('Script completed'));
    });
  }
}
