import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('聊天首屏窗口默认应为 5 条', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final visibleCount =
        container.read(conversationVisibleCountProvider('conv-1'));

    expect(kConversationInitialVisibleCount, 5);
    expect(kConversationVisiblePageSize, 5);
    expect(visibleCount, kConversationInitialVisibleCount);
  });

  test('分页加载应按 5 条递增', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(conversationVisibleCountProvider('conv-2').notifier);

    notifier.state += kConversationVisiblePageSize;

    expect(
      container.read(conversationVisibleCountProvider('conv-2')),
      kConversationInitialVisibleCount + kConversationVisiblePageSize,
    );
  });
}
