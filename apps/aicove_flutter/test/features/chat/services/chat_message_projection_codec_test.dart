import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';

void main() {
  group('ChatMessageProjectionCodec', () {
    test('preserves explicit empty display output separately from canonical raw', () {
      final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: const ApiCallResult(
          rawReplyText: 'SECRET', replyText: '', processedText: '',
          pluginEvents: [], toolResults: [],
        ),
      );
      expect(ChatMessageProjectionCodec.rawReplyText(payload), 'SECRET');
      expect(ChatMessageProjectionCodec.displayReplyText(payload), '');
    });
    test('legacy payload distinguishes missing processing from empty processing', () {
      expect(ChatMessageProjectionCodec.displayReplyText({'rawReplyText': 'old'}), isNull);
      expect(ChatMessageProjectionCodec.displayReplyText({'processedText': ''}), '');
    });

    test('buildRawAssistantPayload should persist hidden thought parts', () {
      final payload = ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: const ApiCallResult(
          rawReplyText: '你好呀',
          replyText: '你好呀',
          processedText: '你好呀',
          hiddenThoughtParts: <Map<String, dynamic>>[
            <String, dynamic>{
              'text': '先想一下怎么回应',
              'thought': true,
            },
          ],
          pluginEvents: [],
          toolResults: [],
        ),
      );

      final hiddenThoughtParts =
          ChatMessageProjectionCodec.hiddenThoughtParts(payload);
      expect(hiddenThoughtParts, hasLength(1));
      expect(hiddenThoughtParts.first['text'], '先想一下怎么回应');
      expect(hiddenThoughtParts.first['thought'], isTrue);
    });
  });
}
