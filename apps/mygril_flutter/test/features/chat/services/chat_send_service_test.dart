import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message msg(String id, String text, DateTime t) => Message(
        id: id,
        role: 'user',
        content: text,
        createdAt: t,
      );

  test('prepareHistory keeps only messages after contextStartMessageId', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_1',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm2',
      messages: [
        msg('m1', 'old 1', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'old 2', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 1', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 2', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 20,
    );

    expect(history.map((m) => m.id).toList(), ['m3', 'm4', 'm5']);
  });

  test('prepareHistory still applies message limit after context slicing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_2',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm1',
      messages: [
        msg('m1', 'old', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'new 1', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 2', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 3', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 2,
    );

    expect(history.map((m) => m.id).toList(), ['m4', 'm5']);
  });

  test('prepareHistory falls back to normal limit when marker is missing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_3',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'missing',
      messages: [
        msg('m1', 'a', now.subtract(const Duration(minutes: 3))),
        msg('m2', 'b', now.subtract(const Duration(minutes: 2))),
        msg('m3', 'c', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m4', 'd', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 3,
    );

    expect(history.map((m) => m.id).toList(), ['m2', 'm3', 'm4']);
  });

  test('non-vision description reuses image prompt before vision fallback',
      () async {
    var visionCalled = false;
    final block = ImageBlock(
      messageId: 'msg_1',
      localPath: '/tmp/demo.png',
      prompt: '1girl, blue hair, smile',
    );

    final description =
        await ChatSendService.resolveImageDescriptionForNonVision(
      imageBlock: block,
      translateWithVision: () async {
        visionCalled = true;
        return 'vision generated description';
      },
    );

    expect(description, '1girl, blue hair, smile');
    expect(visionCalled, isFalse);
  });

  test('non-vision description calls vision fallback when prompt is missing',
      () async {
    var visionCalled = false;
    final block = ImageBlock(
      messageId: 'msg_2',
      localPath: '/tmp/demo2.png',
    );

    final description =
        await ChatSendService.resolveImageDescriptionForNonVision(
      imageBlock: block,
      translateWithVision: () async {
        visionCalled = true;
        return 'vision generated description';
      },
    );

    expect(description, 'vision generated description');
    expect(visionCalled, isTrue);
  });

  test('non-vision assistant image should not inject placeholder text', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'assistant',
      description: '一只猫在草地上',
    );

    expect(text, isNull);
  });

  test('non-vision user image uses neutral description text', () {
    final text = ChatSendService.buildNonVisionImageMessageText(
      role: 'user',
      description: '一只猫在草地上',
    );

    expect(text, isNotNull);
    expect(text, contains('用户刚刚发送了一张图片'));
    expect(text, isNot(contains('[图片]')));
    expect(text, isNot(contains('图片已转换为文本描述')));
  });

  test('buildAssistantImageEventPrompt exports internal media events', () {
    final now = DateTime.now();
    final history = <Message>[
      Message(
        id: 'u1',
        role: 'user',
        content: '你好',
        createdAt: now.subtract(const Duration(minutes: 2)),
      ),
      Message.fromBlocks(
        id: 'a1',
        role: 'assistant',
        blocks: [
          ImageBlock(
            messageId: 'a1',
            localPath: '/tmp/image.png',
            prompt: '1girl, smiling, outdoor',
          ),
        ],
        createdAt: now.subtract(const Duration(minutes: 1)),
      ),
    ];

    final prompt = ChatSendService.buildAssistantImageEventPrompt(history);
    expect(prompt, contains('<internal_media_events>'));
    expect(prompt, contains('assistant_image_sent'));
    expect(prompt, contains("prompt=\"1girl, smiling, outdoor\""));
  });
}
