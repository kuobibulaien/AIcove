import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/regenerate_guidance.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';

void main() {
  final time = DateTime(2026, 10, 9);
  final earlier = Message(
    id: 'u0',
    role: 'user',
    content: '更早的话',
    createdAt: time,
  );
  final user = Message(
    id: 'u1',
    role: 'user',
    content: '今天好累',
    createdAt: time,
  );

  test('未填写或全空白时原样返回历史', () {
    final history = [earlier, user];
    for (final guidance in [null, '', '  \n ']) {
      expect(
        applyRegenerateGuidance(
          history,
          userMessageId: 'u1',
          guidance: guidance,
        ),
        same(history),
      );
    }
  });

  test('纯文本用户消息在请求副本末尾追加意见，不改原消息', () {
    final history = [earlier, user];
    final result = applyRegenerateGuidance(
      history,
      userMessageId: 'u1',
      guidance: '  短一点  ',
    );
    expect(result[0], same(earlier));
    expect(result[1].content, startsWith('今天好累\n\n【本次回复要求】短一点'));
    expect(user.content, '今天好累');
    expect(history[1], same(user));
  });

  test('带块的用户消息追加独立文本块，保留原有块', () {
    final image = ImageBlock(
      messageId: 'u2',
      url: 'https://example.invalid/a.png',
    );
    final blocked = Message(
      id: 'u2',
      role: 'user',
      content: '',
      createdAt: time,
      blocks: [
        TextBlock(messageId: 'u2', content: '看图'),
        image,
      ],
    );
    final result = applyRegenerateGuidance(
      [blocked],
      userMessageId: 'u2',
      guidance: '语气温柔',
    );
    final blocks = result.single.blocks!;
    expect(blocks, hasLength(3));
    expect(blocks[1], same(image));
    expect((blocks.last as TextBlock).content, contains('语气温柔'));
    expect(blocked.blocks, hasLength(2));
  });

  test('找不到源用户消息时不改历史', () {
    final history = [earlier];
    expect(
      applyRegenerateGuidance(history, userMessageId: 'missing', guidance: '短'),
      same(history),
    );
  });
}
