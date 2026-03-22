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
    test('启用后生成语义明确的时间字段', () {
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
      expect(payload!.fields.map((field) => field.name).toList(), <String>[
        TimeAwarenessPlugin.currentDateTimeFieldName,
        TimeAwarenessPlugin.previousUserMessageDateTimeFieldName,
      ]);
      expect(payload.fields.first.value, contains('2026-03-23 10:30:15'));
      expect(payload.fields.last.value, contains('2026-03-22 21:45:30'));
    });

    test('没有上一条用户消息时 previous_user_message_datetime 为 unknown', () {
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
      expect(payload!.fields.last.name,
          TimeAwarenessPlugin.previousUserMessageDateTimeFieldName);
      expect(payload.fields.last.value, 'unknown');
    });

    test('可生成 system-reminder 字段含义说明', () {
      final plugin = TimeAwarenessPlugin(
        TimeAwarenessConfig(
          enabled: true,
        ),
      );

      final guide = plugin.buildSystemReminderFieldGuide();

      expect(guide, contains(TimeAwarenessPlugin.currentDateTimeFieldName));
      expect(
        guide,
        contains(TimeAwarenessPlugin.previousUserMessageDateTimeFieldName),
      );
      expect(guide, contains('unknown'));
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
