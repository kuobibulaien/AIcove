import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_processor.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:aicove_flutter/src/features/content_tags/domain/tag_presentation.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/features/plugins/domain/plugin_content.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../ui/features/chat/pages/chat_interface_test_support.dart';

/// 模型原生思考：接口解析 → 多轮拼接 → 存进 rawPayload → 投影成思考块 →
/// 列表里排在工具调用和标签思维链之前，且不回放给模型。
void main() {
  test('三家接口的非流式响应都能读出原生思考', () {
    final openai = OpenAIAdapter().parseResponse({
      'choices': [
        {
          'message': {'content': '答', 'reasoning_content': '先想想'},
        },
      ],
    });
    expect(openai.reasoning, '先想想');
    expect(openai.text, '答');

    final claude = ClaudeAdapter().parseResponse({
      'content': [
        {'type': 'thinking', 'thinking': '斟酌一下', 'signature': 's'},
        {'type': 'text', 'text': '答'},
      ],
    });
    expect(claude.reasoning, '斟酌一下');
    expect(claude.text, '答');

    final gemini = GeminiAdapter().parseResponse({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': '想一下', 'thought': true},
              {'text': '答'},
            ],
          },
        },
      ],
    });
    expect(gemini.reasoning, '想一下');
    expect(gemini.text, '答');
  });

  test('多轮思考按顺序拼成一段，空轮跳过', () {
    expect(
      joinRoundReasonings(['第一轮', '  ', '第二轮\n']),
      '第一轮\n\n---\n\n第二轮',
    );
    expect(joinRoundReasonings(const []), '');
  });

  test('思考挂在第一条文字消息最前，正文不变', () {
    final built = const ChatMessageProcessor().buildAssistantMessages(
      replyText: '今天是晴天。',
      processedText: '今天是晴天。',
      pluginEvents: const [],
      reasoning: '用户问天气',
    );
    final first = built.messages.first;
    expect(first.content, '今天是晴天。');
    final thinking = first.blocks!.first as ThinkingBlock;
    expect(thinking.title, ChatMessageProcessor.modelThinkingTitle);
    expect(thinking.content, '用户问天气');
    expect(first.blocks![1], isA<TextBlock>());
    expect(built.lastMessageText, '今天是晴天。');
  });

  test('第一条不是文字时思考单独成一条放在最前；没有思考时不动', () {
    final audio = Message.fromBlocks(
      id: 'audio',
      role: 'assistant',
      blocks: [AudioBlock(messageId: 'audio', url: 'a.mp3', text: '语音')],
    );
    final withThinking =
        ChatMessageProcessor.attachModelThinking([audio], '想好了再说');
    expect(withThinking, hasLength(2));
    expect(withThinking.first.blocks!.single, isA<ThinkingBlock>());
    expect(identical(withThinking.last, audio), isTrue);

    final untouched = ChatMessageProcessor.attachModelThinking([audio], '  ');
    expect(identical(untouched.single, audio), isTrue);
  });

  test('思考存进 rawPayload，按 payload 重建投影时还在', () {
    final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
      apiResult: const ApiCallResult(
        replyText: '答',
        processedText: '答',
        pluginEvents: [],
        toolResults: [],
        reasoning: '原生思考',
      ),
    );
    expect(ChatMessageProjectionCodec.reasoning(payload), '原生思考');
    expect(ChatMessageProjectionCodec.reasoning(const {}), '');
  });

  test('思考块不回放给模型', () async {
    final message = ChatMessageProcessor.attachModelThinking(
      [Message.text(id: 'a1', role: 'assistant', content: '正文')],
      '不该发回去',
    ).single;
    final request = await ChatRequestMessageBuilder(
      readImageAsBase64: (_) async => null,
    ).buildRequestMessages(
      [message],
      settings: chatInterfaceTestSettings(),
    );
    expect(request.single['content'], '正文');
    expect(request.toString(), isNot(contains('不该发回去')));
  });

  group('列表投影', () {
    const map = {
      'think': TagPresentationEntry(TagPresentation.fold, '思考'),
    };
    const config = MessageFormatConfig(enableChunking: false);
    Message reply() {
      final message = ChatMessageProcessor.attachModelThinking(
        [
          Message.text(
            id: 'a1',
            role: 'assistant',
            content: '<think>标签思考</think>\n她笑了。',
          ),
        ],
        '原生思考',
      ).single;
      return message.copyWith(blocks: [
        ...message.blocks!,
        ToolBlock(
          messageId: 'a1',
          toolCallId: 'call_1',
          toolName: 'web_search',
          arguments: const {'query': 'x'},
          result: const {'content': 'y'},
        ),
      ]);
    }

    test('顺序是模型思考 → 工具调用 → 标签思考 → 正文', () {
      final items = buildChatMessageListItems(
        messages: [reply()],
        config: config,
        tagPresentation: map,
        showToolCallFolds: true,
      );
      expect(
        items
            .whereType<ChatChunkedMessageItem>()
            .map((item) => item.fold?.title ?? item.chunkText.trim())
            .toList(),
        ['模型思考', 'web_search · x', '思考', '她笑了。'],
      );
    });

    test('关掉思维链时两种思考都隐藏，工具调用和正文照常', () {
      final items = buildChatMessageListItems(
        messages: [reply()],
        config: config,
        tagPresentation: map,
        showThinkingFolds: false,
        showToolCallFolds: true,
      );
      expect(
        items
            .whereType<ChatChunkedMessageItem>()
            .map((item) => item.fold?.title ?? item.chunkText.trim())
            .toList(),
        ['web_search · x', '她笑了。'],
      );
    });

    test('回复拆成多条时，思考和工具调用仍排在整段回复最前', () {
      final reply = const ChatMessageProcessor().buildAssistantMessages(
        replyText: '画好啦 [图片] 喜欢吗',
        processedText: '画好啦 [图片] 喜欢吗',
        pluginEvents: const [],
        contents: const [PluginImageContent('/tmp/a.png')],
        toolCalls: [
          ToolCall(id: 'call_1', name: 'web_search', arguments: {'q': 'x'}),
        ],
        rawToolResults: [
          ToolResult(toolCallId: 'call_1', name: 'web_search', result: 'y'),
        ],
        reasoning: '原生思考',
      ).messages;
      expect(reply.length, greaterThan(1));
      final items = buildChatMessageListItems(
        messages: reply,
        config: config,
        tagPresentation: map,
        showToolCallFolds: true,
      );
      final order = [
        for (final item in items)
          if (item is ChatChunkedMessageItem)
            item.fold?.title ?? item.chunkText.trim()
          else if (item is ChatMessageItem)
            item.message.displayText.trim(),
      ];
      expect(order, ['模型思考', 'web_search', '画好啦', '[图片]', '喜欢吗']);
    });

    test('逐轮回复存档读回后，列表里话术与工具调用按先后交替', () {
      final apiResult = ApiCallResult(
        rawReplyText: '我查一下。\n她笑了。',
        replyText: '我查一下。\n她笑了。',
        processedText: '我查一下。\n她笑了。',
        pluginEvents: const [],
        toolResults: const [],
        toolCalls: const [
          ToolCall(id: 'call_1', name: 'web_search', arguments: {'q': 'x'}),
        ],
        rawToolResults: const [
          ToolResult(toolCallId: 'call_1', name: 'web_search', result: 'y'),
        ],
        reasoning: '原生思考',
        replyRounds: const [
          ReplyRound(
            replyText: '我查一下。',
            processedText: '我查一下。',
            reasoning: '原生思考',
            toolCallIds: ['call_1'],
          ),
          ReplyRound(replyText: '她笑了。', processedText: '她笑了。'),
        ],
      );
      final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: apiResult,
      );
      final reply = const ChatMessageProcessor().buildAssistantMessages(
        replyText: ChatMessageProjectionCodec.rawReplyText(payload)!,
        processedText: ChatMessageProjectionCodec.processedText(payload)!,
        displayReplyText: ChatMessageProjectionCodec.displayReplyText(payload),
        pluginEvents: ChatMessageProjectionCodec.pluginEvents(payload),
        toolCalls: ChatMessageProjectionCodec.toolCalls(payload),
        rawToolResults: ChatMessageProjectionCodec.rawToolResults(payload),
        reasoning: ChatMessageProjectionCodec.reasoning(payload),
        replyRounds: ChatMessageProjectionCodec.replyRounds(payload),
      ).messages;
      final items = buildChatMessageListItems(
        messages: reply,
        config: config,
        tagPresentation: map,
        showToolCallFolds: true,
      );
      expect(
        [
          for (final item in items)
            if (item is ChatChunkedMessageItem)
              item.fold?.title ?? item.chunkText.trim()
            else if (item is ChatMessageItem)
              item.message.displayText.trim(),
        ],
        ['模型思考', '我查一下。', 'web_search', '她笑了。'],
      );
    });

    test('气泡模式分段时思考仍是独立的折叠气泡', () {
      final items = buildChatMessageListItems(
        messages: [
          ChatMessageProcessor.attachModelThinking(
            [
              Message.text(
                id: 'a1',
                role: 'assistant',
                content: '第一句话写在这里。第二句话写在这里。',
              ),
            ],
            '原生思考',
          ).single,
        ],
        config: const MessageFormatConfig(),
      );
      final chunks = items.whereType<ChatChunkedMessageItem>().toList();
      expect(chunks.first.fold?.title, '模型思考');
      expect(chunks.skip(1).every((chunk) => chunk.fold == null), isTrue);
      expect(chunks.length, greaterThan(1));
    });
  });
}
