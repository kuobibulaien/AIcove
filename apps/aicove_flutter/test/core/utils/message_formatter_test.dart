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
        '你好...\u00A0\u00A0\u00A0\u00A0世界',
        cfg,
      );
      expect(chunks, ['你好...', '世界']);
    });

    test('punctuation run should keep internal sequence and split at end', () {
      final chunks = MessageFormatter.formatAndChunkText('等等......然后继续', cfg);
      expect(chunks, ['等等......', '然后继续']);
    });

    test('conservative mode should only split when spaces exceed 3', () {
      final conservativeCfg = cfg.copyWith(chunkPunctuations: const []);
      final threeSpaces = MessageFormatter.formatAndChunkText(
        '你好   世界',
        conservativeCfg,
      );
      final fourSpaces = MessageFormatter.formatAndChunkText(
        '你好    世界',
        conservativeCfg,
      );
      expect(threeSpaces, ['你好   世界']);
      expect(fourSpaces, ['你好', '世界']);
    });
  });

  group('MessageFormatter quote protection', () {
    test('should not split inside Chinese double quotes', () {
      final chunks = MessageFormatter.formatAndChunkText('“你好。世界。”', cfg);
      expect(chunks, ['“你好。世界。”']);
    });

    test('long repeated dialogue preserves chunks and quoted punctuation', () {
      const sentence = '这一段旁白，“引号内的第一句。第二句。”旁白继续。';
      final chunks = MessageFormatter.formatAndChunkText(
        List.filled(1500, sentence).join(),
        cfg,
      );
      expect(chunks, List.filled(1500, sentence));
    });

    test('restores kaomojis inside quotes and outside quotes', () {
      const text = '他说“你好(^_^)。继续。”旁白。然后(^_^)结束。';
      expect(MessageFormatter.formatAndChunkText(text, cfg), [
        '他说“你好(^_^)。继续。”旁白。',
        '然后(^_^)结束。',
      ]);
    });

    test('literal quote tokens do not alias generated placeholders', () {
      const text = '原文\x00QTE0\x00和\x00QTE999999999999999999999\x00原文，“甲。乙。”旁白。';
      expect(MessageFormatter.formatAndChunkText(text, cfg), [text]);
    });

    test('quote protection can be disabled', () {
      expect(
        MessageFormatter.formatAndChunkText(
          '“你好。世界。”',
          cfg.copyWith(protectQuotes: false),
        ),
        ['“你好。', '世界。”'],
      );
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
            'punctuations': ['。', '！'],
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
