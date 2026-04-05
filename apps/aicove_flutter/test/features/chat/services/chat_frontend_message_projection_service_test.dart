import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';

void main() {
  const projectionService = ChatFrontendMessageProjectionService();

  test('raw assistant 从 payload 重建时应沿用原始消息时间', () {
    final rawCreatedAt = DateTime(2026, 4, 4, 23, 10, 0);
    final rawMessage = Message(
      id: 'raw_assistant_text',
      role: 'assistant',
      content: '你好呀',
      createdAt: rawCreatedAt,
      status: 'sent',
      rawPayload: <String, dynamic>{
        'version': ChatMessageProjectionCodec.rawPayloadVersion,
        'rawReplyText': '你好呀',
        'processedText': '你好呀',
      },
    );

    final projected = projectionService.projectMessage(rawMessage);

    expect(projected, hasLength(1));
    expect(projected.single.createdAt, rawCreatedAt);
    expect(projected.single.sourceMessageId, rawMessage.id);
  });

  test('raw assistant 后补多媒体重建时不应把时间戳刷新到当前时刻', () {
    final rawCreatedAt = DateTime(2026, 4, 4, 23, 11, 0);
    final rawMessage = Message(
      id: 'raw_assistant_supplement',
      role: 'assistant',
      content: '先看这里',
      createdAt: rawCreatedAt,
      status: 'sent',
      rawPayload: <String, dynamic>{
        'version': ChatMessageProjectionCodec.rawPayloadVersion,
        'rawReplyText': '先看这里',
        'processedText': '先看这里',
        'supplementInsertOps': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'image',
            'textCharsBefore': 0,
            'forceAppendToTail': false,
            'localPath': '/tmp/demo.png',
            'prompt': 'demo',
          },
        ],
      },
    );

    final projected = projectionService.projectMessage(rawMessage);

    expect(projected, hasLength(2));
    for (final message in projected) {
      expect(message.createdAt, rawCreatedAt);
      expect(message.sourceMessageId, rawMessage.id);
    }
  });
}
