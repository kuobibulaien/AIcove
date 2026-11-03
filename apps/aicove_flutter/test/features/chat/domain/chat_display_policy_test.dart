import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/assistant/domain/assistant_onboarding.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chunking = MessageFormatConfig(enableChunking: true, minSegmentLength: 3);

  test('conversation override wins, null follows global', () {
    expect(
      ChatDisplayPolicy.resolve(
        formatConfig: chunking,
        globalStyle: ChatDisplayStyle.bubble,
      ).style,
      ChatDisplayStyle.bubble,
    );
    expect(
      ChatDisplayPolicy.resolve(
        formatConfig: chunking,
        globalStyle: ChatDisplayStyle.bubble,
        conversationStyle: ChatDisplayStyle.document,
      ).style,
      ChatDisplayStyle.document,
    );
    expect(
      ChatDisplayPolicy.resolve(
        formatConfig: chunking,
        globalStyle: ChatDisplayStyle.document,
        conversationStyle: ChatDisplayStyle.bubble,
      ).style,
      ChatDisplayStyle.bubble,
    );
  });

  test('document disables chunking but keeps the rest of the user config', () {
    final policy = ChatDisplayPolicy.resolve(
      formatConfig: chunking,
      globalStyle: ChatDisplayStyle.document,
    );
    expect(policy.effectiveFormatConfig.enableChunking, isFalse);
    expect(policy.effectiveFormatConfig.minSegmentLength, 3);
    expect(chunking.enableChunking, isTrue, reason: '用户偏好不被改写');
  });

  test('bubble keeps the user chunking config as is', () {
    final policy = ChatDisplayPolicy.resolve(
      formatConfig: chunking,
      globalStyle: ChatDisplayStyle.bubble,
    );
    expect(policy.effectiveFormatConfig, same(chunking));
  });

  test('value equality for provider select', () {
    ChatDisplayPolicy make() => ChatDisplayPolicy.resolve(
          formatConfig: chunking,
          globalStyle: ChatDisplayStyle.document,
        );
    expect(make(), make());
    expect(make().hashCode, make().hashCode);
  });

  test('fromValue tolerates unknown values', () {
    expect(ChatDisplayStyle.fromValue('document'), ChatDisplayStyle.document);
    expect(ChatDisplayStyle.fromValue('weird'), isNull);
    expect(ChatDisplayStyle.fromValue(null), isNull);
  });

  test('AIcove assistant defaults to document unless overridden', () {
    Conversation conv(String id, [ChatDisplayStyle? style]) => Conversation(
          id: id,
          title: id,
          displayName: id,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          chatDisplayStyle: style,
        );
    expect(conv(kAicoveAssistantId).effectiveDisplayStyle,
        ChatDisplayStyle.document);
    expect(
      conv(kAicoveAssistantId, ChatDisplayStyle.bubble).effectiveDisplayStyle,
      ChatDisplayStyle.bubble,
    );
    expect(conv('someone').effectiveDisplayStyle, isNull);
  });

  test('a contact only overrides whether to chunk; punctuation stays global',
      () {
    final global = const MessageFormatConfig(
      filterPunctuation: true,
    ).withActiveSet('aggressive')!;
    final policy = ChatDisplayPolicy.resolve(
      formatConfig: global,
      globalStyle: ChatDisplayStyle.bubble,
      chunkOverride: const ChatChunkOverride(enableChunking: false),
    );
    expect(
      policy.effectiveFormatConfig,
      global.copyWith(enableChunking: false),
    );
    expect(ChatChunkOverride.none.applyTo(global), global);
  });

  test('old per-contact punctuation fields on a contact no longer apply', () {
    final global = const MessageFormatConfig().withActiveSet('aggressive')!;
    final now = DateTime(2026, 10, 23);
    final conv = Conversation(
      id: 'c',
      title: 't',
      displayName: 'd',
      createdAt: now,
      updatedAt: now,
      chunkEnabled: false,
      filterPunctuation: true,
      chunkPunctuationSetId: 'standard',
    );
    expect(
      conv.chunkOverride.applyTo(global),
      global.copyWith(enableChunking: false),
    );
  });

  test('document style turns chunking off even when the contact turned it on',
      () {
    final policy = ChatDisplayPolicy.resolve(
      formatConfig: const MessageFormatConfig(enableChunking: false),
      globalStyle: ChatDisplayStyle.bubble,
      conversationStyle: ChatDisplayStyle.document,
      chunkOverride: const ChatChunkOverride(enableChunking: true),
    );
    expect(policy.effectiveFormatConfig.enableChunking, isFalse);
  });
}
