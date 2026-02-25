import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';

Conversation _buildConversation(String id) {
  final now = DateTime.now();
  return Conversation(
    id: id,
    title: id,
    displayName: id,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sendingProvider only reflects current conversation sending state', () {
    final currentConversationProvider =
        StateProvider<Conversation?>((ref) => _buildConversation('conv_a'));
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider
            .overrideWith((ref) => ref.watch(currentConversationProvider)),
      ],
    );
    addTearDown(container.dispose);

    // 初始状态：两个会话都未发送
    expect(container.read(sendingProvider), isFalse);

    // 仅会话A发送中
    container.read(conversationSendingProvider('conv_a').notifier).state = true;
    expect(container.read(sendingProvider), isTrue);

    // 切到会话B：不应被会话A的发送状态锁住
    container.read(currentConversationProvider.notifier).state =
        _buildConversation('conv_b');
    expect(container.read(sendingProvider), isFalse);

    // 会话B发送中后，当前会话状态才变为 true
    container.read(conversationSendingProvider('conv_b').notifier).state = true;
    expect(container.read(sendingProvider), isTrue);
  });
}
