import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_plugin.dart';

void main() {
  group('TimeAwarenessConfig 默认值', () {
    test('默认启用时间感知', () {
      final config = TimeAwarenessConfig();
      expect(config.enabled, isTrue);
    });

    test('fromJson 缺省 enabled 时默认启用', () {
      final config = TimeAwarenessConfig.fromJson({});
      expect(config.enabled, isTrue);
    });

    test('fromJson 显式 enabled=false 时保持关闭', () {
      final config = TimeAwarenessConfig.fromJson({'enabled': false});
      expect(config.enabled, isFalse);
    });
  });

  group('TimeAwarenessPlugin 间隔提示', () {
    test('存在上一轮时间时输出间隔文案', () async {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
          includeCurrentTime: true,
        ),
      );
      plugin.setLastMessageTime(
        DateTime.now().subtract(
          const Duration(hours: 2, minutes: 10),
        ),
      );

      final prompt = await plugin.getSystemPrompt();

      expect(prompt, isNotNull);
      expect(prompt!, contains('当前时间: '));
      expect(prompt, contains('距离上次对话已过去'));
    });
  });

  group('ChatSendService 时间锚点选择', () {
    test('最后一条为用户消息时，回退到上一条消息时间', () {
      final now = DateTime(2026, 2, 27, 12, 30);
      final assistantMessage = Message(
        id: 'a1',
        role: 'assistant',
        content: 'hello',
        createdAt: now.subtract(const Duration(hours: 3)),
      );
      final currentUserMessage = Message(
        id: 'u1',
        role: 'user',
        content: 'hi',
        createdAt: now,
      );

      final anchor = ChatSendService.resolveTimeAwarenessLastMessageTime([
        assistantMessage,
        currentUserMessage,
      ]);

      expect(anchor, assistantMessage.createdAt);
    });

    test('最后一条不是用户消息时，使用最后一条消息时间', () {
      final now = DateTime(2026, 2, 27, 12, 30);
      final first = Message(
        id: 'a1',
        role: 'assistant',
        content: 'hello',
        createdAt: now.subtract(const Duration(hours: 2)),
      );
      final last = Message(
        id: 'a2',
        role: 'assistant',
        content: 'still here',
        createdAt: now.subtract(const Duration(minutes: 10)),
      );

      final anchor = ChatSendService.resolveTimeAwarenessLastMessageTime([
        first,
        last,
      ]);

      expect(anchor, last.createdAt);
    });
  });
}
