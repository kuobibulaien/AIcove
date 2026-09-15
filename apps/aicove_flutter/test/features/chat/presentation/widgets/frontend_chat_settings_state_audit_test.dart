import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/ui/features/chat/widgets/chat_message_selection.dart';

void main() {
  test('menu edit can enter and leave selection with no messages', () {
    final selection = ChatMessageSelection();
    addTearDown(selection.dispose);
    selection.enter();
    expect(selection.active, isTrue);
    expect(selection.count, 0);
    selection.clear();
    expect(selection.active, isFalse);
  });
}
