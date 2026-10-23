import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter_test/flutter_test.dart';

const TagPresentationMap _map = {
  'think': TagPresentationEntry(TagPresentation.fold, '思考'),
  'status': TagPresentationEntry(TagPresentation.fold, '状态栏'),
};

const MessageFormatConfig _documentConfig =
    MessageFormatConfig(enableChunking: false);

Message _assistantWithTools(String text) => Message.fromBlocks(
      id: 'a1',
      role: 'assistant',
      createdAt: DateTime(2026, 10, 21),
      blocks: [
        TextBlock(messageId: 'a1', content: text),
        ToolBlock(
          messageId: 'a1',
          toolCallId: 'call_1',
          toolName: 'web_search',
          arguments: const {'query': '天气'},
          result: const {'content': '晴，22 度'},
        ),
        ToolBlock(
          messageId: 'a1',
          toolName: ChatRequestMessageBuilder.internalImageContextToolName,
          result: const {'prompt': 'internal'},
        ),
      ],
    );

void main() {
  test('文档模式把工具调用投影成正文前的折叠段，内部上下文块不显示', () {
    final items = buildChatMessageListItems(
      messages: [_assistantWithTools('今天是晴天。')],
      config: _documentConfig,
      tagPresentation: _map,
      showToolCallFolds: true,
    );
    final chunks = items.whereType<ChatChunkedMessageItem>().toList();
    expect(chunks, hasLength(2));
    expect(chunks[0].fold?.title, 'web_search · 天气');
    expect(chunks[0].fold?.content, contains('"query": "天气"'));
    expect(chunks[0].fold?.content, contains('晴，22 度'));
    expect(chunks[1].fold, isNull);
    expect(chunks[1].chunkText, '今天是晴天。');
  });

  test('相邻的工具调用按时间线收拢成一个过程折叠段', () {
    Message text(String id, String content) => Message.text(
          id: id,
          role: 'assistant',
          content: content,
          createdAt: DateTime(2026, 10, 21),
        );
    ToolBlock call(String messageId, String name, String command) => ToolBlock(
          messageId: messageId,
          toolCallId: 'call_$command',
          toolName: name,
          arguments: {'command': command},
          result: {'content': '$command ok'},
        );
    Message tools(String id, List<ToolBlock> blocks) => Message.fromBlocks(
          id: id,
          role: 'assistant',
          createdAt: DateTime(2026, 10, 21),
          blocks: blocks,
        );

    final items = buildChatMessageListItems(
      messages: [
        text('a1', '我先看看目录。'),
        tools('t1', [call('t1', 'bash', 'ls')]),
        tools('t2', [call('t2', 'bash', 'pwd'), call('t2', 'read', 'cat')]),
        text('a2', '看完了。'),
        tools('t3', [call('t3', 'bash', 'echo')]),
      ],
      config: _documentConfig,
      showToolCallFolds: true,
    );
    final chunks = items.whereType<ChatChunkedMessageItem>().toList();
    expect(
      [
        for (final item in items)
          if (item is ChatChunkedMessageItem)
            item.fold?.title ?? item.chunkText
          else if (item is ChatMessageItem)
            item.message.content,
      ],
      ['我先看看目录。', 'bash、read · 3 次', '看完了。', 'bash · echo'],
    );
    final merged = chunks[0].fold!.content;
    expect(merged.indexOf('ls ok'), lessThan(merged.indexOf('pwd ok')));
    expect(merged.indexOf('pwd ok'), lessThan(merged.indexOf('cat ok')));
  });

  test('工具调用开关关闭时消息照旧整条显示', () {
    final items = buildChatMessageListItems(
      messages: [_assistantWithTools('今天是晴天。')],
      config: _documentConfig,
      tagPresentation: _map,
    );
    expect(items.whereType<ChatChunkedMessageItem>(), isEmpty);
    expect(items.whereType<ChatMessageItem>(), hasLength(1));
  });

  test('隐藏思维链只去掉思考折叠段，状态栏等其他折叠照常显示', () {
    final items = buildChatMessageListItems(
      messages: [
        Message.text(
          id: 'a1',
          role: 'assistant',
          content: '<think>想一想</think>\n<status>HP 10</status>\n她笑了。',
          createdAt: DateTime(2026, 10, 21),
        ),
      ],
      config: _documentConfig,
      tagPresentation: _map,
      showThinkingFolds: false,
    );
    final folds = items
        .whereType<ChatChunkedMessageItem>()
        .map((item) => item.fold?.title)
        .toList();
    expect(folds, ['状态栏', null]);
  });

  test('codemode 工具折叠段显示脚本和脚本里的嵌套调用', () {
    final message = Message.fromBlocks(
      id: 'a2',
      role: 'assistant',
      createdAt: DateTime(2026, 10, 22),
      blocks: [
        TextBlock(messageId: 'a2', content: '下好了。'),
        ToolBlock(
          messageId: 'a2',
          toolCallId: 'call_cm',
          toolName: 'codemode',
          arguments: const {'code': 'const r = await tools.bash({ command: "ls" });\nreturn r.output;'},
          result: const {
            'content': 'Script completed\nWall time 1.2 seconds\nOutput:\nindex.html',
            'codemodeCalls': [
              {'id': 'call_cm/1', 'name': 'bash', 'args': '{"command":"ls"}', 'status': 'ok', 'durationMs': 1200},
              {'id': 'call_cm/2', 'name': 'read', 'args': '{"path":"x"}', 'status': 'error', 'error': 'File not found'},
              {'id': 'call_cm/3', 'name': 'workspace_list', 'args': '{}', 'status': 'ok', 'durationMs': 40},
            ],
          },
        ),
      ],
    );
    final items = buildChatMessageListItems(
      messages: [message],
      config: _documentConfig,
      showToolCallFolds: true,
    );
    final fold = items.whereType<ChatChunkedMessageItem>().first.fold!;
    expect(fold.title, 'bash、read、workspace_list · 3 次 · 1 个失败');
    expect(fold.content, contains('```js\nconst r = await tools.bash'));
    expect(fold.content, isNot(contains('"code"')));
    expect(fold.content, contains('脚本里调用了 3 个工具'));
    expect(fold.content, contains('- `workspace_list` 完成 · 40 毫秒'));
    expect(fold.content, contains('- `bash ls` 完成 · 1.2 秒'));
    expect(fold.content, contains('- `read x` 失败：File not found'));
    expect(fold.content, contains('Script completed'));
  });

  test('codemode 只调了一个工具时标题是该工具和它的关键参数，截断的参数也能读出', () {
    final message = Message.fromBlocks(
      id: 'a3',
      role: 'assistant',
      createdAt: DateTime(2026, 10, 22),
      blocks: [
        ToolBlock(
          messageId: 'a3',
          toolCallId: 'call_cm',
          toolName: 'codemode',
          arguments: const {'code': 'await tools.bash({ command: "curl" });'},
          result: const {
            'content': 'Script completed',
            'codemodeCalls': [
              {'id': 'call_cm/1', 'name': 'bash', 'args': '{"command":"curl -sL https://example.com/a/very/long/path/that/got/cut', 'status': 'ok'},
            ],
          },
        ),
      ],
    );
    final items = buildChatMessageListItems(
      messages: [message],
      config: _documentConfig,
      showToolCallFolds: true,
    );
    expect(
      items.whereType<ChatChunkedMessageItem>().first.fold!.title,
      'bash · curl -sL https://example.com/a/very/long…',
    );
  });

  test('文档模式每轮回复末尾跟一个操作栏，跨工具轮次算同一轮，生成中的占位不显示', () {
    Message msg(String id, String role, String content, {String status = 'sent'}) =>
        Message.text(
          id: id,
          role: role,
          content: content,
          createdAt: DateTime(2026, 10, 22, 10),
          status: status,
        );
    final tools = Message.fromBlocks(
      id: 't1',
      role: 'assistant',
      createdAt: DateTime(2026, 10, 22, 10),
      blocks: [
        ToolBlock(messageId: 't1', toolName: 'bash', arguments: const {'command': 'ls'}),
      ],
    );
    final items = buildChatMessageListItems(
      messages: [
        msg('u1', 'user', '看看目录'),
        msg('a1', 'assistant', '我先看看。'),
        tools,
        msg('a2', 'assistant', '看完了。'),
        msg('u2', 'user', '再来'),
        msg('a3', 'assistant', '生成中', status: 'sending'),
      ],
      config: _documentConfig,
      showToolCallFolds: true,
      showReplyActions: true,
    );
    final actions = items.whereType<ChatReplyActionsItem>().toList();
    expect(actions, hasLength(2));
    expect(actions.first.message.id, 'a2');
    expect(actions.first.messageIds, ['a1', 't1', 'a2']);
    expect(actions.first.copyText, '我先看看。\n\n看完了。');
    expect(actions.first.finished, isTrue);
    expect(actions.last.message.id, 'a3');
    expect(actions.last.finished, isFalse);
    final index = items.indexOf(actions.first);
    expect(
      (items[index + 1] as ChatMessageItem).message.id,
      'u2',
    );
  });

  test('没正常结束的回复后面跟一行运行状态，正常完成的没有', () {
    Message reply(String id, Map<String, dynamic>? payload) => Message(
          id: id,
          role: 'assistant',
          content: '我看看这个项目……',
          createdAt: DateTime(2026, 10, 22),
          rawPayload: payload,
        );
    final items = buildChatMessageListItems(
      messages: [
        reply('done', null),
        reply('cut', {'runStatus': 'truncated', 'stopReason': 'length'}),
        reply('odd', {'runStatus': 'somethingElse'}),
      ],
      config: _documentConfig,
    );
    final statuses = items.whereType<ChatRunStatusItem>().toList();
    expect(statuses, hasLength(1));
    expect(statuses.single.status, ChatRunStatus.truncated);
    expect(statuses.single.associatedMessageId, 'cut');
    final cutIndex = items.indexWhere(
      (i) => i is ChatMessageItem && i.message.id == 'cut',
    );
    expect(items[cutIndex + 1], same(statuses.single));
  });

  test('被停止且没有正文的回复只显示状态行，不画空气泡', () {
    final items = buildChatMessageListItems(
      messages: [
        Message(
          id: 'stopped',
          role: 'assistant',
          content: '',
          createdAt: DateTime(2026, 10, 22),
          rawPayload: const {'runStatus': 'cancelled'},
        ),
      ],
      config: _documentConfig,
    );
    expect(items, hasLength(1));
    expect((items.single as ChatRunStatusItem).status, ChatRunStatus.cancelled);
  });

  test('生成中的消息不显示运行状态', () {
    final items = buildChatMessageListItems(
      messages: [
        Message(
          id: 'live',
          role: 'assistant',
          content: '还在写',
          createdAt: DateTime(2026, 10, 22),
          status: 'sending',
          rawPayload: const {'runStatus': 'truncated'},
        ),
      ],
      config: _documentConfig,
    );
    expect(items.whereType<ChatRunStatusItem>(), isEmpty);
  });
}
