import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/utils/message_formatter.dart';

void main() {
  const cfg = MessageFormatConfig(
    enableChunking: true,
    minSegmentLength: 0,
    chunkPunctuations: ['...', '。', '！', '？', '!', '?', '…'],
  );

  group('MessageFormatter whitespace segmentation', () {
    test('ascii spaces after punctuation should split', () {
      final chunks = MessageFormatter.formatAndChunkText('你好...    世界', cfg);
      expect(chunks, ['你好...', '世界']);
    });

    test('fullwidth spaces after punctuation should split', () {
      final chunks = MessageFormatter.formatAndChunkText('你好...　　　世界', cfg);
      expect(chunks, ['你好...', '世界']);
    });

    test('nbsp spaces after punctuation should split', () {
      final chunks =
          MessageFormatter.formatAndChunkText('你好...\u00A0\u00A0\u00A0世界', cfg);
      expect(chunks, ['你好...', '世界']);
    });

    test('punctuation run should keep internal sequence and split at end', () {
      final chunks = MessageFormatter.formatAndChunkText('等等......然后继续', cfg);
      expect(chunks, ['等等......', '然后继续']);
    });
  });
}
