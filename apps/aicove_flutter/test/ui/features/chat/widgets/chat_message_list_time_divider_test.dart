import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_list_items.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message(String id, DateTime createdAt) => Message.text(
      id: id,
      role: 'assistant',
      content: '你好',
      createdAt: createdAt,
    );

void main() {
  final messages = [
    _message('a', DateTime(2026, 10, 21, 9)),
    _message('b', DateTime(2026, 10, 21, 9, 5)),
    _message('c', DateTime(2026, 10, 21, 10)),
  ];
  const config = MessageFormatConfig(enableChunking: false);

  test('time dividers follow the time awareness plugin switch', () {
    final shown = buildChatMessageListItems(messages: messages, config: config);
    expect(shown.whereType<ChatTimeDividerItem>(), hasLength(2));

    final hidden = buildChatMessageListItems(
      messages: messages,
      config: config,
      showTimeDividers: false,
    );
    expect(hidden.whereType<ChatTimeDividerItem>(), isEmpty);
  });

  test('a long gap still shows the avatar when dividers are hidden', () {
    final hidden = buildChatMessageListItems(
      messages: messages,
      config: config,
      showTimeDividers: false,
    );
    final avatars = {
      for (final item in hidden.whereType<ChatMessageItem>())
        item.message.id: item.showAvatar,
    };
    expect(avatars, {'a': true, 'b': false, 'c': true});
  });
}
