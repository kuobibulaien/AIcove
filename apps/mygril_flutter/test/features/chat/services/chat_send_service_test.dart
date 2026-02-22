import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Message msg(String id, String text, DateTime t) => Message(
        id: id,
        role: 'user',
        content: text,
        createdAt: t,
      );

  test('prepareHistory keeps only messages after contextStartMessageId', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_1',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm2',
      messages: [
        msg('m1', 'old 1', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'old 2', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 1', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 2', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 20,
    );

    expect(history.map((m) => m.id).toList(), ['m3', 'm4', 'm5']);
  });

  test('prepareHistory still applies message limit after context slicing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_2',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'm1',
      messages: [
        msg('m1', 'old', now.subtract(const Duration(minutes: 4))),
        msg('m2', 'new 1', now.subtract(const Duration(minutes: 3))),
        msg('m3', 'new 2', now.subtract(const Duration(minutes: 2))),
        msg('m4', 'new 3', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m5', 'new user', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 2,
    );

    expect(history.map((m) => m.id).toList(), ['m4', 'm5']);
  });

  test('prepareHistory falls back to normal limit when marker is missing', () {
    final now = DateTime.now();
    final conv = Conversation(
      id: 'conv_3',
      title: 'Chat',
      displayName: 'Chat',
      createdAt: now,
      updatedAt: now,
      contextStartMessageId: 'missing',
      messages: [
        msg('m1', 'a', now.subtract(const Duration(minutes: 3))),
        msg('m2', 'b', now.subtract(const Duration(minutes: 2))),
        msg('m3', 'c', now.subtract(const Duration(minutes: 1))),
      ],
    );
    final userMsg = msg('m4', 'd', now);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final service = container.read(chatSendServiceProvider);

    final history = service.prepareHistory(
      conv: conv,
      userMsg: userMsg,
      limit: 3,
    );

    expect(history.map((m) => m.id).toList(), ['m2', 'm3', 'm4']);
  });
}
