import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/data/enhanced_dialogue_service.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';

void main() {
  Message _msg({
    required String id,
    required String role,
    required String text,
    required DateTime time,
  }) {
    return Message(
      id: id,
      role: role,
      content: text,
      createdAt: time,
    );
  }

  test('buildContext keeps bootstrap + recent rounds only', () {
    final now = DateTime.now();
    final m1 = _msg(
      id: 'm1',
      role: 'user',
      text: 'u1',
      time: now.subtract(const Duration(minutes: 7)),
    );
    final m2 = _msg(
      id: 'm2',
      role: 'assistant',
      text: 'a1',
      time: now.subtract(const Duration(minutes: 6)),
    );
    final m3 = _msg(
      id: 'm3',
      role: 'user',
      text: 'u2',
      time: now.subtract(const Duration(minutes: 5)),
    );
    final m4 = _msg(
      id: 'm4',
      role: 'assistant',
      text: 'a2',
      time: now.subtract(const Duration(minutes: 4)),
    );
    final m5 = _msg(
      id: 'm5',
      role: 'user',
      text: 'u3',
      time: now.subtract(const Duration(minutes: 3)),
    );
    final m6 = _msg(
      id: 'm6',
      role: 'assistant',
      text: 'a3',
      time: now.subtract(const Duration(minutes: 2)),
    );
    final m7 = _msg(
      id: 'm7',
      role: 'user',
      text: 'u4',
      time: now.subtract(const Duration(minutes: 1)),
    );

    final conversation = Conversation(
      id: 'conv_1',
      title: 'Chat',
      displayName: 'Chat',
      personaPrompt: '原始人设',
      createdAt: now,
      updatedAt: now,
      messages: [m1, m2, m3, m4, m5, m6, m7],
    );

    const service = EnhancedDialogueService();
    final context = service.buildContext(
      conversation: conversation,
      targetUserMessage: m7,
      enhancerSystemPrompt: '增强系统',
      bootstrapUserMessage: '先执行增强任务',
      recentRounds: 3,
    );

    expect(context.history.first.role, 'user');
    expect(context.history.first.content, '先执行增强任务');
    expect(
      context.history.skip(1).map((m) => m.id).toList(),
      ['m3', 'm4', 'm5', 'm6', 'm7'],
    );
    expect(context.conversation.personaPrompt, contains('增强系统'));
    expect(context.conversation.personaPrompt, contains('原始人设'));
    expect(context.sessionId, startsWith('enhance_conv_1_'));
  });

  test('buildContext respects contextStartMessageId marker', () {
    final now = DateTime.now();
    final m1 = _msg(
      id: 'm1',
      role: 'user',
      text: 'old user',
      time: now.subtract(const Duration(minutes: 5)),
    );
    final m2 = _msg(
      id: 'm2',
      role: 'assistant',
      text: 'old ai',
      time: now.subtract(const Duration(minutes: 4)),
    );
    final m3 = _msg(
      id: 'm3',
      role: 'user',
      text: 'new user 1',
      time: now.subtract(const Duration(minutes: 3)),
    );
    final m4 = _msg(
      id: 'm4',
      role: 'assistant',
      text: 'new ai 1',
      time: now.subtract(const Duration(minutes: 2)),
    );
    final m5 = _msg(
      id: 'm5',
      role: 'user',
      text: 'new user 2',
      time: now.subtract(const Duration(minutes: 1)),
    );

    final conversation = Conversation(
      id: 'conv_2',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm2',
      messages: [m1, m2, m3, m4, m5],
    );

    const service = EnhancedDialogueService();
    final context = service.buildContext(
      conversation: conversation,
      targetUserMessage: m5,
      enhancerSystemPrompt: '',
      bootstrapUserMessage: '',
      recentRounds: 5,
    );

    expect(context.history.map((m) => m.id).toList(), ['m3', 'm4', 'm5']);
  });

  test('extractEnhancedText uses tag and has fallback', () {
    const service = EnhancedDialogueService();

    final tagged = service.extractEnhancedText(
      processedText: '前缀 <enhance>这句才是最终回复</enhance> 后缀',
      rawReplyText: 'ignored',
    );
    expect(tagged, '这句才是最终回复');

    final fallback = service.extractEnhancedText(
      processedText: '',
      rawReplyText: '没有标签也要回退',
    );
    expect(fallback, '没有标签也要回退');
  });
}
