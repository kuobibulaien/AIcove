import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';

void main() {
  group('ChatMessageProjectionCodec', () {
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
