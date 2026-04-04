import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';

void main() {
  group('Message.sourceMessageIdOrSelf', () {
    test('优先返回 sourceMessageId，适用于前端投影消息', () {
      final message = Message(
        id: 'assistant_proj_01',
        role: 'assistant',
        sourceMessageId: 'assistant_raw_01',
        content: '你好',
        createdAt: DateTime(2026, 3, 27, 10),
      );

      expect(message.sourceMessageIdOrSelf, 'assistant_raw_01');
    });

    test('sourceMessageId 为空白时回退到自身 id', () {
      final message = Message(
        id: 'user_raw_01',
        role: 'user',
        sourceMessageId: '   ',
        content: '你好',
        createdAt: DateTime(2026, 3, 27, 10),
      );

      expect(message.sourceMessageIdOrSelf, 'user_raw_01');
    });
  });
}
