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

  group('MessageFormatter protected components (ADR0047)', () {
    test('fenced code block stays one chunk, prose around it still splits', () {
      const text = '先看代码。然后运行。\n```dart\nfinal a = 1。\nfinal b = 2！\n```\n跑完了。再见。';
      expect(MessageFormatter.formatAndChunkText(text, cfg), [
        '先看代码。',
        '然后运行。',
        '```dart\nfinal a = 1。\nfinal b = 2！\n```',
        '跑完了。',
        '再见。',
      ]);
    });

    test('unclosed fence is protected to the end and marked open', () {
      final chunks = MessageFormatter.formatAndChunk(
        '说明。\n```\n第一行。\n第二行。',
        cfg,
      );
      expect(chunks.map((c) => c.text), ['说明。', '```\n第一行。\n第二行。']);
      expect(chunks.map((c) => c.openEnded), [false, true]);
    });

    test('code inside a component keeps escapes and spacing untouched', () {
      const code = '```\nprint("a\\nb")\n    indented。x\n```';
      expect(MessageFormatter.formatAndChunkText(code, cfg), [code]);
    });

    test('caller ranges protect tag components', () {
      const text = '前言。<t>第一句。第二句。</t>结尾。收尾。';
      final start = text.indexOf('<t>');
      final end = text.indexOf('</t>') + 4;
      expect(
        MessageFormatter.formatAndChunkText(
          text,
          cfg,
          protectedRanges: [ProtectedTextRange(start, end)],
        ),
        ['前言。', '<t>第一句。第二句。</t>', '结尾。', '收尾。'],
      );
    });

    test('ranges starting inside a code block are code text, not components', () {
      const text = '```\n<t>代码。\n```\n<t>正文里的组件。还在。</t>';
      final inner = text.indexOf('<t>');
      final outer = text.lastIndexOf('<t>');
      expect(
        MessageFormatter.formatAndChunkText(
          text,
          cfg,
          protectedRanges: [
            ProtectedTextRange(inner, text.length, closed: false),
            ProtectedTextRange(outer, text.length),
          ],
        ),
        ['```\n<t>代码。\n```', '<t>正文里的组件。还在。</t>'],
      );
    });

    test('components are not merged with short neighbours or filtered', () {
      final config = cfg.copyWith(
        minSegmentLength: 10,
        filterPunctuation: true,
        filterPunctuations: const ['。'],
      );
      const text = '好，\n```\nx。\n```';
      expect(MessageFormatter.formatAndChunkText(text, config), [
        '好，',
        '```\nx。\n```',
      ]);
    });

    test('chunking disabled returns the raw text untouched', () {
      const text = '一句。\n```\n两句。\n```';
      expect(
        MessageFormatter.formatAndChunkText(
          text,
          cfg.copyWith(enableChunking: false),
        ),
        [text],
      );
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
