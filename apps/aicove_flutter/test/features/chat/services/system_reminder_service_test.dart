import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/services/system_reminder_service.dart';

void main() {
  group('SystemReminderService', () {
    test('生成 <system-reminder> 标签包裹内容', () {
      const service = SystemReminderService();

      final wrapped = service.wrapReminderContent(
        'current_datetime=2026-03-23 10:00\n'
        'previous_user_message_datetime=2026-03-22 21:30',
      );

      expect(
        wrapped,
        '<system-reminder>\n'
        'current_datetime=2026-03-23 10:00\n'
        'previous_user_message_datetime=2026-03-22 21:30\n'
        '</system-reminder>',
      );
    });

    test('生成标签含义说明', () {
      const service = SystemReminderService();

      final prompt = service.buildReminderSemanticsPrompt();

      expect(prompt, contains('<system-reminder>'));
      expect(prompt, contains('系统注入'));
      expect(prompt, contains('不是用户消息'));
      expect(prompt, contains('不要原样复述'));
    });

    test('合并多个 reminder 内容时会过滤空字符串并按空行拼接', () {
      const service = SystemReminderService();

      final merged = service.mergeReminderContents([
        'current_datetime=2026-03-23 10:00',
        '',
        'image_generation_failed=true\nimage_generation_failure_reason=timeout',
      ]);

      expect(
        merged,
        'current_datetime=2026-03-23 10:00\n\n'
        'image_generation_failed=true\n'
        'image_generation_failure_reason=timeout',
      );
    });

    test('把 reminder system message 插入到最后一条 user 消息前', () {
      const service = SystemReminderService();
      final messages = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '上一轮回复',
        },
        {
          'role': 'user',
          'content': '这一轮新的用户消息',
        },
      ];

      final updated = service.insertReminderBeforeLastUser(
        messages: messages,
        reminderContent:
            'current_datetime=2026-03-23 10:00\nprevious_user_message_datetime=2026-03-22 21:30',
      );

      expect(updated, hasLength(3));
      expect(
        updated.map((message) => message['role']).toList(),
        <String>['assistant', 'system', 'user'],
      );
      expect(
        updated[1]['content'],
        '<system-reminder>\n'
        'current_datetime=2026-03-23 10:00\n'
        'previous_user_message_datetime=2026-03-22 21:30\n'
        '</system-reminder>',
      );
      expect(updated[2]['content'], '这一轮新的用户消息');
    });

    test('无 user 消息时回退为追加到末尾', () {
      const service = SystemReminderService();
      final messages = <Map<String, dynamic>>[
        {
          'role': 'assistant',
          'content': '只有助手消息',
        },
      ];

      final updated = service.insertReminderBeforeLastUser(
        messages: messages,
        reminderContent:
            'current_datetime=2026-03-23 10:00\nprevious_user_message_datetime=unknown',
      );

      expect(updated, hasLength(2));
      expect(updated.last['role'], 'system');
      expect(
        updated.last['content'],
        '<system-reminder>\n'
        'current_datetime=2026-03-23 10:00\n'
        'previous_user_message_datetime=unknown\n'
        '</system-reminder>',
      );
    });

    test('合并多段 reminder 内容时用空行分隔', () {
      const service = SystemReminderService();

      final merged = service.mergeReminderContents(<String?>[
        'current_datetime=2026-03-23 10:00',
        '',
        'image_generation_failure=true',
      ]);

      expect(
        merged,
        'current_datetime=2026-03-23 10:00\n\nimage_generation_failure=true',
      );
    });
  });
}
