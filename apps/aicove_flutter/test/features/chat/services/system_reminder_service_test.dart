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
      expect(prompt, contains('系统补充信息'));
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

    test('把 reminder 消息以 user 角色插入到最后一条 user 消息前', () {
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
            '当前时间为2026-03-23 10:00:00 +08:00 (周一)。用户上一次发消息的时间为2026-03-22 21:30:00 +08:00 (周日)。自行判断当前与历史对话的关系。',
      );

      expect(updated, hasLength(3));
      expect(
        updated.map((message) => message['role']).toList(),
        <String>['assistant', 'user', 'user'],
      );
      expect(
        updated[1]['content'],
        '<system-reminder>\n'
        '当前时间为2026-03-23 10:00:00 +08:00 (周一)。用户上一次发消息的时间为2026-03-22 21:30:00 +08:00 (周日)。自行判断当前与历史对话的关系。\n'
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
            '当前时间为2026-03-23 10:00:00 +08:00 (周一)。自行判断当前与历史对话的关系。',
      );

      expect(updated, hasLength(2));
      expect(updated.last['role'], 'user');
      expect(
        updated.last['content'],
        '<system-reminder>\n'
        '当前时间为2026-03-23 10:00:00 +08:00 (周一)。自行判断当前与历史对话的关系。\n'
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
