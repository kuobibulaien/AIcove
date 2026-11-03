import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';

final _ref = Provider<Ref>((ref) => ref);
final _active = StateProvider<String?>((ref) => 'a');

void main() {
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer(overrides: [
      activeConversationProvider.overrideWith((ref) {
        final id = ref.watch(_active);
        if (id == null) return null;
        final now = DateTime(2026);
        return Conversation(id: id, title: id, displayName: id,
            createdAt: now, updatedAt: now, messages: const []);
      }),
    ]);
  });
  tearDown(() => container.dispose());

  test('switching conversations clears a legacy manually assigned status', () {
    container.read(chatStatusProvider.notifier).state = ChatStatus.generatingVoice;
    container.read(_active.notifier).state = 'b';
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });
  test('background tasks stay with their conversation across switches', () {
    final ref = container.read(_ref);
    beginConversationVoiceTask(ref, 'a');
    beginConversationImageTask(ref, 'b');
    expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
    container.read(_active.notifier).state = 'b';
    expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
    endConversationVoiceTask(ref, 'a');
    expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
    container.read(_active.notifier).state = 'a';
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

  test('main phase wins and concurrent tasks release independently', () {
    final ref = container.read(_ref);
    beginConversationVoiceTask(ref, 'a');
    beginConversationVoiceTask(ref, 'a');
    beginConversationImageTask(ref, 'a');
    setConversationMainChatStatus(ref, 'a', ChatStatus.thinking);
    endConversationVoiceTask(ref, 'a');
    expect(container.read(chatStatusProvider), ChatStatus.thinking);
    setConversationMainChatStatus(ref, 'a', ChatStatus.idle);
    expect(container.read(chatStatusProvider), ChatStatus.generatingVoice);
    endConversationVoiceTask(ref, 'a');
    expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
    endConversationImageTask(ref, 'a');
    expect(container.read(chatStatusProvider), ChatStatus.idle);
    endConversationVoiceTask(ref, 'a');
    expect(container.read(conversationVoiceTaskCountProvider('a')), 0);
  });

  test('helpers repair legacy writes even when the main phase is unchanged', () {
    final ref = container.read(_ref);
    container.read(chatStatusProvider.notifier).state = ChatStatus.toolCalling;
    setConversationMainChatStatus(ref, 'a', ChatStatus.idle);
    expect(container.read(chatStatusProvider), ChatStatus.idle);
    beginConversationVoiceTask(ref, 'a');
    container.read(chatStatusProvider.notifier).state = ChatStatus.thinking;
    beginConversationImageTask(ref, 'b');
    expect(container.read(chatStatusProvider), ChatStatus.thinking);
    endConversationVoiceTask(ref, 'a');
    expect(container.read(chatStatusProvider), ChatStatus.idle);
    container.read(_active.notifier).state = 'b';
    expect(container.read(chatStatusProvider), ChatStatus.generatingImage);
    container.read(_active.notifier).state = null;
    expect(container.read(chatStatusProvider), ChatStatus.idle);
  });

}
