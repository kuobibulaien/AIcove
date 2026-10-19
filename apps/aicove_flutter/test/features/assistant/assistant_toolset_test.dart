import 'dart:convert';

import 'package:aicove_flutter/src/features/assistant/application/assistant_toolset.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_context_preview.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17);
  final role = Conversation(
    id: 'role_li',
    title: 'role_li',
    displayName: '小理',
    createdAt: now,
    updatedAt: now,
    messages: const [],
  );

  test(
    'a failed plugin reports a fixed explanation, never the exception',
    () async {
      final toolset = AssistantToolset(
        roles: () async => [role],
        presets: () async => const [],
        previewContext: (_) async => const ChatContextPreview(
          modelId: 'deepseek/deepseek-flash',
          presetName: null,
          messages: [],
          messageTokens: [],
          tools: [],
          sources: [],
          plugins: [
            ChatContextPluginStatus(
              name: '长期记忆',
              injected: false,
              reason: 'FormatException: 记忆里的私密内容',
              failed: true,
            ),
            ChatContextPluginStatus(
              name: '绘图',
              injected: false,
              reason: '角色未开启',
            ),
          ],
          inputTokens: 10,
          inputLimit: 64000,
          notes: ['未知宏：私密聊天内容'],
        ),
        readDoc: (_) async => null,
      );
      final tool = toolset.tools().singleWhere(
        (t) => t.name == 'aicove_inspect_context',
      );

      final raw = (await tool.handler({'role_id': 'role_li'}))!;
      final report = jsonDecode(raw) as Map<String, dynamic>;
      final plugins = report['plugins'] as List;

      expect(raw, isNot(contains('私密')));
      expect((plugins[0] as Map)['reason'], contains('设置 · 调试 · 联系人上下文'));
      expect((plugins[1] as Map)['reason'], '角色未开启');
      expect(report['warning_count'], 1);
    },
  );
}
