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

    test('default set splits on three or more spaces', () {
      final standard = cfg.copyWith(chunkPunctuations: const []);
      expect(MessageFormatter.formatAndChunkText('你好  世界', standard), [
        '你好  世界',
      ]);
      expect(MessageFormatter.formatAndChunkText('你好   世界', standard), [
        '你好',
        '世界',
      ]);
    });

    MessageFormatConfig withSet({
      List<String> punctuations = const [],
      bool splitOnNewline = true,
      int spaceRun = kDefaultChunkSpaceRun,
    }) => cfg.copyWith(
      chunkPunctuationSets: [
        MessageChunkPunctuationSet(
          id: 'x',
          punctuations: punctuations,
          splitOnNewline: splitOnNewline,
          spaceRun: spaceRun,
        ),
      ],
      activeChunkPunctuationSetId: 'x',
    );

    test('a set can keep line breaks inside one chunk', () {
      final config = withSet(splitOnNewline: false);
      expect(MessageFormatter.formatAndChunkText('第一行\n第二行', config), [
        '第一行\n第二行',
      ]);
      expect(MessageFormatter.formatAndChunkText('第一行\n第二行', withSet()), [
        '第一行',
        '第二行',
      ]);
    });

    test('punctuation still splits across a kept line break', () {
      final config = withSet(punctuations: ['。'], splitOnNewline: false);
      expect(MessageFormatter.formatAndChunkText('好的。\n你呢\n还好吗', config), [
        '好的。',
        '你呢\n还好吗',
      ]);
    });

    test('a set picks how many spaces split, or none', () {
      expect(
        MessageFormatter.formatAndChunkText('嗯 好的  走吧', withSet(spaceRun: 1)),
        ['嗯', '好的', '走吧'],
      );
      expect(
        MessageFormatter.formatAndChunkText('嗯 好的  走吧', withSet(spaceRun: 2)),
        ['嗯 好的', '走吧'],
      );
      expect(
        MessageFormatter.formatAndChunkText('你好    世界', withSet(spaceRun: 0)),
        ['你好    世界'],
      );
    });

    test('newline and space rules round-trip and default for old data', () {
      const set = MessageChunkPunctuationSet(
        id: 'x',
        punctuations: ['。'],
        splitOnNewline: false,
        spaceRun: 2,
      );
      expect(MessageChunkPunctuationSet.fromJson(set.toJson()), set);
      final legacy = MessageChunkPunctuationSet.fromJson({
        'id': 'y',
        'punctuations': ['。'],
      });
      expect(legacy.splitOnNewline, isTrue);
      expect(legacy.spaceRun, kDefaultChunkSpaceRun);
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

  group('MessageFormatConfig chunk punctuation sets', () {
    const legacyDefault = ['。', '！', '？', '，', '、', '；', '…'];

    test('defaults to a standard set and an aggressive set', () {
      const config = MessageFormatConfig();
      expect(config.chunkPunctuationSets.map((s) => s.displayName), [
        '默认',
        '激进',
      ]);
      expect(config.activeChunkPunctuationSetId, 'standard');
      expect(config.effectiveChunkPunctuations, isEmpty);
      expect(config.splitOnNewline, isTrue);
      expect(config.chunkSpaceRun, 3);
      final aggressive = config.withActiveSet('aggressive')!;
      expect(aggressive.effectiveChunkPunctuations, contains('，'));
      expect(MessageFormatConfig.fromJson(const {}), config);
    });

    test('round-trips once migrated, keeping edits to built-in sets', () {
      final edited = const MessageFormatConfig().withSetPunctuations(
        'standard',
        ['。'],
      )!;
      final restored = MessageFormatConfig.fromJson(edited.toJson());
      expect(restored, edited);
      expect(restored.effectiveChunkPunctuations, ['。']);
    });

    test('old built-in sets are replaced; a punctuated choice goes aggressive', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': ['。', '！', '？'],
        'activeChunkPunctuationSetId': 'simple',
        'chunkPunctuationSets': [
          {'id': 'legacy', 'name': '当前', 'punctuations': ['～']},
          {'id': 'conservative', 'name': '保守', 'punctuations': <String>[]},
          {'id': 'simple', 'name': '精简', 'punctuations': ['。', '！', '？']},
          {'id': 'detailed', 'name': '详细', 'punctuations': legacyDefault},
          {'id': 'set_1', 'name': '我的', 'punctuations': ['♪']},
        ],
      });
      expect(config.chunkPunctuationSets.map((s) => s.id), [
        'standard',
        'aggressive',
        'set_1',
      ]);
      expect(config.activeChunkPunctuationSetId, 'aggressive');
      expect(config.effectiveChunkPunctuations, contains('，'));
    });

    test('an old choice without punctuation goes to the standard set', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': <String>[],
        'activeChunkPunctuationSetId': 'conservative',
        'chunkPunctuationSets': [
          {'id': 'conservative', 'name': '保守', 'punctuations': <String>[]},
        ],
      });
      expect(config.activeChunkPunctuationSetId, 'standard');
      expect(config.effectiveChunkPunctuations, isEmpty);
    });

    test('an old user-made set stays chosen', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': ['♪'],
        'activeChunkPunctuationSetId': 'set_1',
        'chunkPunctuationSets': [
          {'id': 'simple', 'name': '精简', 'punctuations': ['。']},
          {'id': 'set_1', 'name': '我的', 'punctuations': ['♪']},
        ],
      });
      expect(config.activeChunkPunctuationSetId, 'set_1');
      expect(config.effectiveChunkPunctuations, ['♪']);
    });

    test('a kept user set keeps the runtime list it was using', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': ['。', '！'],
        'activeChunkPunctuationSetId': 'set_1',
        'chunkPunctuationSets': [
          {'id': 'set_1', 'name': '我的', 'punctuations': ['？']},
        ],
      });
      expect(config.activeChunkPunctuationSetId, 'set_1');
      expect(config.chunkPunctuations, ['。', '！']);
    });

    test('an old set is mapped by the punctuation actually in effect', () {
      final config = MessageFormatConfig.fromJson({
        'chunkPunctuations': ['。'],
        'activeChunkPunctuationSetId': 'conservative',
        'chunkPunctuationSets': [
          {'id': 'conservative', 'name': '保守', 'punctuations': <String>[]},
        ],
      });
      expect(config.activeChunkPunctuationSetId, 'aggressive');
    });

    test('migrated sets are cleaned, so copies and round-trips stay equal', () {
      final config = MessageFormatConfig.fromJson({
        'activeChunkPunctuationSetId': 'set_1',
        'chunkPunctuationSets': [
          {'id': 'set_1', 'punctuations': [' ♪ ', '♪', '']},
          {'id': 'set_1', 'punctuations': ['★']},
        ],
      });
      expect(config.chunkPunctuationSets[2].punctuations, ['♪']);
      expect(config.copyWith(), config);
      final once = MessageFormatConfig.fromJson(config.toJson());
      expect(once, config);
      expect(MessageFormatConfig.fromJson(once.toJson()), once);
    });

    test('a flat legacy list migrates by whether it has punctuation', () {
      expect(
        MessageFormatConfig.fromJson({
          'chunkPunctuations': legacyDefault,
        }).activeChunkPunctuationSetId,
        'aggressive',
      );
      expect(
        MessageFormatConfig.fromJson({
          'chunkPunctuations': <String>[],
        }).activeChunkPunctuationSetId,
        'standard',
      );
    });
  });
}
