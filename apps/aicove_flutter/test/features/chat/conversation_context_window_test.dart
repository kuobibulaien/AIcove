import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation_context_window.dart';

void main() {
  final messages = [
    for (final id in ['old', 'boundary', 'new'])
      Message.text(
        id: id,
        role: 'user',
        content: id,
        createdAt: DateTime(2026),
      ),
  ];
  test('absent boundary preserves canonical history', () {
    expect(sliceConversationContext(messages, null), messages);
    expect(sliceConversationContext(messages, '  '), messages);
  });
  test('only messages after the boundary are selected', () {
    expect(sliceConversationContext(messages, ' boundary ').single.id, 'new');
  });
  test('a boundary at the last message produces an empty window', () {
    expect(sliceConversationContext(messages, 'new'), isEmpty);
  });
  test('an invalid explicit boundary must block history recovery', () {
    expect(
      () => sliceConversationContext(messages, 'missing'),
      throwsStateError,
    );
  });
}
