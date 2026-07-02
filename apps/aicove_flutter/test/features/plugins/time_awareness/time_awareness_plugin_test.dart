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

  group('TimeAwarenessPlugin 系统提醒数据', () {
    test('启用后生成简洁中文时间提示', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
        ),
      );
      final payload = plugin.buildSystemReminderPayload(
        currentTime: DateTime(2026, 3, 23, 10, 30, 15),
        previousUserMessageTime: DateTime(2026, 3, 22, 21, 45, 30),
      );

      expect(payload, isNotNull);
      final content = payload!.rawContent!;
      expect(content, contains('当前时间:'));
      expect(content, contains('2026-03-23 10:30:15'));
      expect(content, contains('用户上一次发消息的时间为'));
      expect(content, contains('2026-03-22 21:45:30'));
      expect(content, contains('自行判断当前与历史对话的关系'));
    });

    test('没有上一条用户消息时省略该部分', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
        ),
      );
      final payload = plugin.buildSystemReminderPayload(
        currentTime: DateTime(2026, 3, 23, 10, 30, 15),
        previousUserMessageTime: null,
      );

      expect(payload, isNotNull);
      final content = payload!.rawContent!;
      expect(content, contains('当前时间:'));
      expect(content, isNot(contains('用户上一次发消息的时间为')));
      expect(content, contains('自行判断当前与历史对话的关系'));
    });

    test('关闭当前时间注入后不再包含当前时间', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
          includeCurrentTime: false,
        ),
      );

      final payload = plugin.buildSystemReminderPayload(
        currentTime: DateTime(2026, 3, 23, 10, 30, 15),
        previousUserMessageTime: DateTime(2026, 3, 22, 21, 45, 30),
      );

      expect(payload, isNotNull);
      final content = payload!.rawContent!;
      expect(content, isNot(contains('当前时间:')));
      expect(content, contains('用户上一次发消息的时间为'));
    });

    test('关闭当前时间注入且无上一条用户消息时返回 null', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
          includeCurrentTime: false,
        ),
      );

      final payload = plugin.buildSystemReminderPayload(
        currentTime: DateTime(2026, 3, 23, 10, 30, 15),
        previousUserMessageTime: null,
      );

      expect(payload, isNull);
    });

    test('字段含义说明会描述当前时间模板和历史时间戳', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
        ),
      );

      final guide = plugin.buildSystemReminderFieldGuide();

      expect(guide, contains('{datetime}'));
      expect(guide, contains('设备本地时间'));
      expect(guide, contains('[YYYY-MM-DD HH:mm]'));
    });

    test('当前时间模板会真实影响 reminder 文案', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
          currentTimePromptTemplate: '系统时钟显示 {datetime}',
        ),
      );

      final payload = plugin.buildSystemReminderPayload(
        currentTime: DateTime(2026, 3, 23, 10, 30, 15),
        previousUserMessageTime: null,
      );

      expect(payload, isNotNull);
      expect(payload!.rawContent, contains('系统时钟显示 2026-03-23 10:30:15'));
    });
  });

  group('ChatSendService 上一条用户消息时间选择', () {
    test('最后一条为当前用户消息时，回退到上一条用户消息时间', () {
      final now = DateTime(2026, 2, 27, 12, 30);
      final previousUserMessage = Message(
        id: 'u0',
        role: 'user',
        content: 'earlier',
        createdAt: now.subtract(const Duration(hours: 6)),
      );
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

      final anchor =
          ChatSendService.resolveTimeAwarenessPreviousUserMessageTime([
        previousUserMessage,
        assistantMessage,
        currentUserMessage,
      ]);

      expect(anchor, previousUserMessage.createdAt);
    });

    test('最后一条不是当前用户消息时，使用最近一条用户消息时间', () {
      final now = DateTime(2026, 2, 27, 12, 30);
      final first = Message(
        id: 'u1',
        role: 'user',
        content: 'hello',
        createdAt: now.subtract(const Duration(hours: 2)),
      );
      final middle = Message(
        id: 'a1',
        role: 'assistant',
        content: 'still here',
        createdAt: now.subtract(const Duration(hours: 1)),
      );
      final last = Message(
        id: 'a2',
        role: 'assistant',
        content: 'assistant reply',
        createdAt: now.subtract(const Duration(minutes: 10)),
      );

      final anchor =
          ChatSendService.resolveTimeAwarenessPreviousUserMessageTime([
        first,
        middle,
        last,
      ]);

      expect(anchor, first.createdAt);
    });

    test('只有当前用户消息时返回 null', () {
      final now = DateTime(2026, 2, 27, 12, 30);
      final currentUserMessage = Message(
        id: 'u1',
        role: 'user',
        content: 'hi',
        createdAt: now,
      );

      final anchor =
          ChatSendService.resolveTimeAwarenessPreviousUserMessageTime([
        currentUserMessage,
      ]);

      expect(anchor, isNull);
    });
  });
}
