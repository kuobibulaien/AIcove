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
      final chunks = MessageFormatter.formatAndChunkText('你好...　　　　世界', cfg);
      expect(chunks, ['你好...', '世界']);
    });

    test('nbsp spaces after punctuation should split', () {
      final chunks = MessageFormatter.formatAndChunkText(
          '你好...\u00A0\u00A0\u00A0\u00A0世界', cfg);
      expect(chunks, ['你好...', '世界']);
    });

    test('punctuation run should keep internal sequence and split at end', () {
      final chunks = MessageFormatter.formatAndChunkText('等等......然后继续', cfg);
      expect(chunks, ['等等......', '然后继续']);
    });

    test('conservative mode should only split when spaces exceed 3', () {
      final conservativeCfg = cfg.copyWith(chunkPunctuations: const []);
      final threeSpaces =
          MessageFormatter.formatAndChunkText('你好   世界', conservativeCfg);
      final fourSpaces =
          MessageFormatter.formatAndChunkText('你好    世界', conservativeCfg);
      expect(threeSpaces, ['你好   世界']);
      expect(fourSpaces, ['你好', '世界']);
    });
  });

  group('MessageFormatter quote protection', () {
    test('should not split inside Chinese double quotes', () {
      final chunks = MessageFormatter.formatAndChunkText('“你好。世界。”', cfg);
      expect(chunks, ['“你好。世界。”']);
    });

    test('should not split inside Chinese single quotes', () {
      final chunks = MessageFormatter.formatAndChunkText('‘甲。乙。’', cfg);
      expect(chunks, ['‘甲。乙。’']);
    });
  });

  group('MessageFormatConfig punctuation sets', () {
    test('should read active punctuation set from json', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuationSets': [
          {
            'id': 'set_a',
            'name': 'A',
            'punctuations': ['。', '！']
          },
          {'id': 'set_b', 'name': 'B', 'punctuations': []},
        ],
        'activeChunkPunctuationSetId': 'set_b',
      });

      expect(config.activeChunkPunctuationSet?.id, 'set_b');
      expect(config.chunkPunctuations, isEmpty);
      expect(config.effectiveChunkPunctuations, isEmpty);
    });

    test('legacy chunk punctuations should become a named current set', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': ['...', '。'],
      });

      expect(config.activeChunkPunctuationSet?.id, 'legacy');
      expect(config.chunkPunctuationSets.first.punctuations, ['...', '。']);
    });
  });
}
