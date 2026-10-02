import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
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
}
