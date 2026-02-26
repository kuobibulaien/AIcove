import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/message_formatter.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';

void main() {
  group('streamTextEndsWithChunkBoundary', () {
    test('命中分段标点时返回 true', () {
      final config = MessageFormatConfig(
        enableChunking: true,
        minSegmentLength: 2,
        chunkPunctuations: const ['。', '！', '？'],
      );

      expect(streamTextEndsWithChunkBoundary('你好。', config), isTrue);
      expect(streamTextEndsWithChunkBoundary('你好！', config), isTrue);
      expect(streamTextEndsWithChunkBoundary('你好？', config), isTrue);
    });

    test('未命中标点或长度不足时返回 false', () {
      final config = MessageFormatConfig(
        enableChunking: true,
        minSegmentLength: 3,
        chunkPunctuations: const ['。'],
      );

      expect(streamTextEndsWithChunkBoundary('你好', config), isFalse);
      expect(streamTextEndsWithChunkBoundary('好。', config), isFalse);
    });

    test('关闭分段时始终返回 false', () {
      final config = MessageFormatConfig(
        enableChunking: false,
        chunkPunctuations: const ['。'],
      );

      expect(streamTextEndsWithChunkBoundary('你好。', config), isFalse);
    });
  });
}
