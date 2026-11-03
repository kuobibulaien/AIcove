import 'package:aicove_flutter/src/features/chat/application/chat_view_prefs.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../ui/features/chat/pages/chat_interface_test_support.dart';

void main() {
  final now = DateTime(2026, 10, 23);
  Conversation conv({double? scale, bool? expand, bool? hide}) => Conversation(
    id: 'c1',
    title: 't',
    displayName: 'd',
    createdAt: now,
    updatedAt: now,
    imagePreviewScale: scale,
    expandAudioText: expand,
    hideUserAvatar: hide,
  );

  test('a contact without its own choice keeps the old global values', () {
    final global = chatInterfaceTestSettings().copyWith(
      imagePreviewScale: 0.8,
      expandAudioText: false,
      hideUserAvatar: false,
    );
    expect(
      ChatViewPrefs.resolve(conv(), global),
      const ChatViewPrefs(
        imagePreviewScale: 0.8,
        expandAudioText: false,
        hideUserAvatar: false,
      ),
    );
  });

  test('the contact\'s own choice wins over the global value', () {
    final global = chatInterfaceTestSettings().copyWith(
      imagePreviewScale: 0.8,
      expandAudioText: false,
      hideUserAvatar: false,
    );
    expect(
      ChatViewPrefs.resolve(
        conv(scale: 1.3, expand: true, hide: true),
        global,
      ),
      const ChatViewPrefs(
        imagePreviewScale: 1.3,
        expandAudioText: true,
        hideUserAvatar: true,
      ),
    );
  });

  test('nothing loaded yet falls back to the defaults', () {
    expect(ChatViewPrefs.resolve(null, null), const ChatViewPrefs());
  });
}
